import Compression
import Foundation

/// A ZIP archive read whole from memory: its central directory, and each
/// entry's contents on request, stored or deflated, with ZIP64 sizes and
/// offsets. Enough for the archives editors write their projects as; not
/// for encrypted, split or otherwise compressed ones, which are refused.
///
/// Kept apart from anything Resolve-specific so it can be shared by other
/// readers of zipped projects later.
struct ResolveZIPArchive: Sendable {
    struct Entry: Sendable, Equatable {
        /// The path inside the archive, with forward slashes.
        var name: String
        var method: UInt16
        var flags: UInt16
        var crc32: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    enum Failure: Error, Equatable {
        /// No end of central directory: not a ZIP archive, or cut short.
        case notAnArchive
        /// The directory or an entry's data is damaged.
        case corrupt
        /// An entry compressed some way other than stored or deflated.
        case unsupportedMethod(UInt16)
        case encrypted
        /// An entry larger than `maximumEntrySize` once expanded.
        case tooLarge
        case missingEntry(String)
    }

    /// Larger than any project's XML; refused beyond it, so a small archive
    /// can't expand to fill memory.
    static let maximumEntrySize: UInt64 = 512 * 1024 * 1024
    /// More entries than any project has.
    static let maximumEntryCount = 100_000

    let entries: [Entry]
    private let data: Data

    /// Whether data starts as a ZIP archive does, with a local file header
    /// or, for an empty archive, the end of central directory.
    static func looksLikeArchive(_ data: Data) -> Bool {
        let head = [UInt8](data.prefix(4))
        return head == [0x50, 0x4B, 0x03, 0x04] || head == [0x50, 0x4B, 0x05, 0x06]
    }

    init(_ data: Data) throws {
        // Indexed from zero, whatever slice it came from.
        let data = Data(data)
        self.data = data
        entries = try Self.readDirectory(data)
    }

    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// An entry's contents, expanded and checked against its CRC.
    func contents(of name: String) throws -> Data {
        guard let entry = entry(named: name) else { throw Failure.missingEntry(name) }
        return try contents(of: entry)
    }

    func contents(of entry: Entry) throws -> Data {
        if entry.flags & 0x1 != 0 { throw Failure.encrypted }
        guard entry.uncompressedSize <= Self.maximumEntrySize else { throw Failure.tooLarge }
        let header = entry.localHeaderOffset
        guard header <= UInt64(data.count), let signature = data.uint32(at: Int(header)), signature == 0x0403_4B50,
              let nameLength = data.uint16(at: Int(header) + 26), let extraLength = data.uint16(at: Int(header) + 28) else {
            throw Failure.corrupt
        }
        let start = header + 30 + UInt64(nameLength) + UInt64(extraLength)
        let (end, overflow) = start.addingReportingOverflow(entry.compressedSize)
        guard !overflow, end <= UInt64(data.count) else { throw Failure.corrupt }
        let compressed = data.subdata(in: Int(start)..<Int(end))

        let expanded: Data
        switch entry.method {
        case 0:
            guard entry.compressedSize == entry.uncompressedSize else { throw Failure.corrupt }
            expanded = compressed
        case 8:
            expanded = try Self.inflate(compressed, size: Int(entry.uncompressedSize))
        default:
            throw Failure.unsupportedMethod(entry.method)
        }
        guard Self.crc32(expanded) == entry.crc32 else { throw Failure.corrupt }
        return expanded
    }

    // MARK: - Directory

    private static func readDirectory(_ data: Data) throws -> [Entry] {
        guard let end = endOfCentralDirectory(in: data) else { throw Failure.notAnArchive }
        guard let count16 = data.uint16(at: end + 10), let size32 = data.uint32(at: end + 12),
              let offset32 = data.uint32(at: end + 16) else { throw Failure.corrupt }
        var count = UInt64(count16)
        var size = UInt64(size32)
        var offset = UInt64(offset32)

        // ZIP64: the real numbers are in a record of their own, found by a
        // locator just before the end of central directory.
        if count16 == 0xFFFF || size32 == 0xFFFF_FFFF || offset32 == 0xFFFF_FFFF {
            let locator = end - 20
            guard locator >= 0, data.uint32(at: locator) == 0x0706_4B50,
                  let recordOffset = data.uint64(at: locator + 8), recordOffset < UInt64(data.count),
                  data.uint32(at: Int(recordOffset)) == 0x0606_4B50,
                  let count64 = data.uint64(at: Int(recordOffset) + 32), let size64 = data.uint64(at: Int(recordOffset) + 40),
                  let offset64 = data.uint64(at: Int(recordOffset) + 48) else { throw Failure.corrupt }
            count = count64
            size = size64
            offset = offset64
        }
        guard count <= UInt64(maximumEntryCount) else { throw Failure.corrupt }
        let (directoryEnd, overflow) = offset.addingReportingOverflow(size)
        guard !overflow, directoryEnd <= UInt64(data.count) else { throw Failure.corrupt }

        var entries: [Entry] = []
        var cursor = Int(offset)
        for _ in 0..<count {
            guard data.uint32(at: cursor) == 0x0201_4B50,
                  let flags = data.uint16(at: cursor + 8), let method = data.uint16(at: cursor + 10),
                  let crc = data.uint32(at: cursor + 16), let compressed32 = data.uint32(at: cursor + 20),
                  let uncompressed32 = data.uint32(at: cursor + 24), let nameLength = data.uint16(at: cursor + 28),
                  let extraLength = data.uint16(at: cursor + 30), let commentLength = data.uint16(at: cursor + 32),
                  let local32 = data.uint32(at: cursor + 42) else { throw Failure.corrupt }
            let nameStart = cursor + 46
            let extraStart = nameStart + Int(nameLength)
            let next = extraStart + Int(extraLength) + Int(commentLength)
            guard next <= data.count else { throw Failure.corrupt }
            let nameBytes = data.subdata(in: nameStart..<extraStart)
            let name = String(decoding: nameBytes, as: UTF8.self).replacingOccurrences(of: "\\", with: "/")

            var entry = Entry(
                name: name, method: method, flags: flags, crc32: crc, compressedSize: UInt64(compressed32),
                uncompressedSize: UInt64(uncompressed32), localHeaderOffset: UInt64(local32)
            )
            try readZIP64Extra(data.subdata(in: extraStart..<(extraStart + Int(extraLength))), into: &entry,
                               compressed32: compressed32, uncompressed32: uncompressed32, local32: local32)
            entries.append(entry)
            cursor = next
        }
        return entries
    }

    /// Sizes and offsets too large for the directory's 32 bits, which are
    /// written there as all ones and given in full in the ZIP64 extra field,
    /// in this order, only those that overflowed.
    private static func readZIP64Extra(
        _ extra: Data, into entry: inout Entry, compressed32: UInt32, uncompressed32: UInt32, local32: UInt32
    ) throws {
        var cursor = 0
        while cursor + 4 <= extra.count {
            guard let id = extra.uint16(at: cursor), let length = extra.uint16(at: cursor + 2) else { throw Failure.corrupt }
            let body = cursor + 4
            guard body + Int(length) <= extra.count else { throw Failure.corrupt }
            if id == 0x0001 {
                var field = body
                func next() throws -> UInt64 {
                    guard field + 8 <= body + Int(length), let value = extra.uint64(at: field) else { throw Failure.corrupt }
                    field += 8
                    return value
                }
                if uncompressed32 == 0xFFFF_FFFF { entry.uncompressedSize = try next() }
                if compressed32 == 0xFFFF_FFFF { entry.compressedSize = try next() }
                if local32 == 0xFFFF_FFFF { entry.localHeaderOffset = try next() }
            }
            cursor = body + Int(length)
        }
    }

    /// Where the end of central directory record starts: the last one, in
    /// the final 64 KiB where a comment may follow it.
    private static func endOfCentralDirectory(in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let lowest = max(0, data.count - 22 - 0xFFFF)
        var position = data.count - 22
        while position >= lowest {
            if data.uint32(at: position) == 0x0605_4B50 { return position }
            position -= 1
        }
        return nil
    }

    // MARK: - Contents

    /// Raw deflate, as ZIP stores it, which is what Compression's zlib
    /// algorithm reads.
    private static func inflate(_ compressed: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard !compressed.isEmpty else { throw Failure.corrupt }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { destination in
            compressed.withUnsafeBytes { source in
                compression_decode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, size,
                    source.bindMemory(to: UInt8.self).baseAddress!, compressed.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == size else { throw Failure.corrupt }
        return output
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { bytes in
            for byte in bytes { crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    /// Little-endian integers at a byte offset from the start, or nil past
    /// the end. The data must be indexed from zero.
    fileprivate func uint16(at offset: Int) -> UInt16? { littleEndian(at: offset) }
    fileprivate func uint32(at offset: Int) -> UInt32? { littleEndian(at: offset) }
    fileprivate func uint64(at offset: Int) -> UInt64? { littleEndian(at: offset) }

    private func littleEndian<Value: FixedWidthInteger>(at offset: Int) -> Value? {
        let size = MemoryLayout<Value>.size
        guard offset >= 0, offset <= count - size else { return nil }
        return withUnsafeBytes { bytes in
            Value(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: Value.self))
        }
    }
}
