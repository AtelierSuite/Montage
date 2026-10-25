import Compression
import Foundation

/// Reads a ZIP archive through its central directory, a file at a time, so
/// an archive of several gigabytes is never held in memory. Entries stored
/// as they are or compressed with deflate are read, ZIP64 included.
/// Encrypted entries and other compression methods aren't.
final class ZipArchive {
    struct Entry: Equatable, Sendable {
        /// The entry's path in the archive, with forward slashes.
        let path: String
        let method: UInt16
        let flags: UInt16
        let crc32: UInt32
        let compressedSize: UInt64
        /// The size of the entry's contents once read.
        let size: UInt64
        let localHeaderOffset: UInt64

        var isDirectory: Bool { path.hasSuffix("/") }
        var isEncrypted: Bool { flags & 1 != 0 }
        var fileName: String { path.split(separator: "/").last.map(String.init) ?? "" }
    }

    enum Error: Swift.Error, Equatable {
        /// Not a ZIP archive: no end of central directory record.
        case notAnArchive
        /// A ZIP archive whose records or contents don't add up.
        case damaged
        /// An entry compressed with a method other than store or deflate.
        case unsupportedMethod(UInt16)
        /// An encrypted entry.
        case encrypted
    }

    static let stored: UInt16 = 0
    static let deflated: UInt16 = 8

    let url: URL
    private(set) var entries: [Entry] = []
    private let handle: FileHandle
    private let fileSize: UInt64

    private static let chunkSize = 256 * 1024

    init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        do {
            fileSize = try handle.seekToEnd()
            entries = try readCentralDirectory()
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    // MARK: - Reading entries

    /// The entry's contents, refused when they'd be larger than `limit`.
    func data(for entry: Entry, limit: Int) throws -> Data {
        guard entry.size <= UInt64(limit) else { throw Error.damaged }
        var data = Data(capacity: Int(entry.size))
        try read(entry) { data.append(contentsOf: $0) }
        return data
    }

    /// Writes the entry's contents to a new file at `destination`.
    func extract(_ entry: Entry, to destination: URL) throws {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
        let output = try FileHandle(forWritingTo: destination)
        do {
            try read(entry) { try output.write(contentsOf: $0) }
            try output.close()
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Writes every file in the archive into `folder`, keeping the folders
    /// they're in. Entries whose path would land outside the folder, and the
    /// resource forks Finder adds, are passed over. Returns the files written.
    @discardableResult
    func extractAll(into folder: URL) throws -> [URL] {
        var written: [URL] = []
        for entry in entries where !entry.isDirectory {
            guard let components = Self.safeComponents(of: entry.path),
                  components.first != "__MACOSX", components.last?.hasPrefix("._") == false else { continue }
            let destination = components.reduce(folder) { $0.appending(path: $1) }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try extract(entry, to: destination)
            written.append(destination)
        }
        return written
    }

    /// An entry's path as folder and file names that stay inside the folder
    /// it's unpacked into, or nil for an absolute path or one that climbs out.
    static func safeComponents(of path: String) -> [String]? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.hasPrefix("/") else { return nil }
        let components = normalized.split(separator: "/").map(String.init).filter { $0 != "." && !$0.isEmpty }
        guard !components.isEmpty, !components.contains("..") else { return nil }
        return components
    }

    /// Hands the entry's contents to `consume` a piece at a time, checking
    /// their size and checksum against the central directory's.
    private func read(_ entry: Entry, consume: (UnsafeRawBufferPointer) throws -> Void) throws {
        guard !entry.isEncrypted else { throw Error.encrypted }
        let start = try dataOffset(of: entry)
        guard start <= fileSize, entry.compressedSize <= fileSize - start else { throw Error.damaged }
        var crc = CRC32()
        var produced: UInt64 = 0
        let check: (UnsafeRawBufferPointer) throws -> Void = { buffer in
            produced += UInt64(buffer.count)
            guard produced <= entry.size else { throw Error.damaged }
            crc.update(buffer)
            try consume(buffer)
        }
        switch entry.method {
        case Self.stored:
            guard entry.compressedSize == entry.size else { throw Error.damaged }
            try copyStored(from: start, count: entry.size, consume: check)
        case Self.deflated:
            try inflate(from: start, compressedSize: entry.compressedSize, consume: check)
        default:
            throw Error.unsupportedMethod(entry.method)
        }
        guard produced == entry.size, crc.value == entry.crc32 else { throw Error.damaged }
    }

    private func copyStored(from offset: UInt64, count: UInt64, consume: (UnsafeRawBufferPointer) throws -> Void) throws {
        try handle.seek(toOffset: offset)
        var remaining = count
        while remaining > 0 {
            let chunk = try handle.read(upToCount: Int(min(remaining, UInt64(Self.chunkSize)))) ?? Data()
            guard !chunk.isEmpty else { throw Error.damaged }
            try chunk.withUnsafeBytes(consume)
            remaining -= UInt64(chunk.count)
        }
    }

    /// Raw deflate, which is what the Compression framework's zlib is.
    private func inflate(from offset: UInt64, compressedSize: UInt64, consume: (UnsafeRawBufferPointer) throws -> Void) throws {
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            throw Error.damaged
        }
        defer { compression_stream_destroy(stream) }
        let input = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { input.deallocate() }
        let output = UnsafeMutablePointer<UInt8>.allocate(capacity: Self.chunkSize)
        defer { output.deallocate() }

        try handle.seek(toOffset: offset)
        var remaining = compressedSize
        stream.pointee.src_ptr = UnsafePointer(input)
        stream.pointee.src_size = 0
        var status = COMPRESSION_STATUS_OK
        repeat {
            if stream.pointee.src_size == 0, remaining > 0 {
                let chunk = try handle.read(upToCount: Int(min(remaining, UInt64(Self.chunkSize)))) ?? Data()
                guard !chunk.isEmpty else { throw Error.damaged }
                chunk.copyBytes(to: input, count: chunk.count)
                stream.pointee.src_ptr = UnsafePointer(input)
                stream.pointee.src_size = chunk.count
                remaining -= UInt64(chunk.count)
            }
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = Self.chunkSize
            let flags = remaining == 0 ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            status = compression_stream_process(stream, flags)
            guard status != COMPRESSION_STATUS_ERROR else { throw Error.damaged }
            let produced = Self.chunkSize - stream.pointee.dst_size
            if produced > 0 {
                try consume(UnsafeRawBufferPointer(start: output, count: produced))
            } else if status == COMPRESSION_STATUS_OK, remaining == 0, stream.pointee.src_size == 0 {
                // Out of input with the stream unfinished: cut short.
                throw Error.damaged
            }
        } while status != COMPRESSION_STATUS_END
    }

    // MARK: - Central directory

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let zip64EndSignature: UInt32 = 0x0606_4B50
    private static let centralHeaderSignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50

    private func bytes(at offset: UInt64, count: Int) throws -> Data {
        guard offset <= fileSize, UInt64(count) <= fileSize - offset else { throw Error.damaged }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw Error.damaged }
        return data
    }

    private func readCentralDirectory() throws -> [Entry] {
        // The end record is the last thing in the file, before a comment of
        // at most 64 KB.
        let fixedEndSize = 22
        guard fileSize >= UInt64(fixedEndSize) else { throw Error.notAnArchive }
        let tailSize = Int(min(fileSize, UInt64(fixedEndSize + 0xFFFF)))
        let tailStart = fileSize - UInt64(tailSize)
        let tail = try bytes(at: tailStart, count: tailSize)
        guard let endIndex = stride(from: tailSize - fixedEndSize, through: 0, by: -1)
            .first(where: { tail.uint32(at: $0) == Self.endOfCentralDirectorySignature }) else {
            throw Error.notAnArchive
        }
        let endOffset = tailStart + UInt64(endIndex)
        var count = UInt64(tail.uint16(at: endIndex + 10))
        var directorySize = UInt64(tail.uint32(at: endIndex + 12))
        var directoryOffset = UInt64(tail.uint32(at: endIndex + 16))

        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            guard endOffset >= 20 else { throw Error.damaged }
            let locator = try bytes(at: endOffset - 20, count: 20)
            guard locator.uint32(at: 0) == Self.zip64LocatorSignature else { throw Error.damaged }
            let zip64Offset = locator.uint64(at: 8)
            let zip64End = try bytes(at: zip64Offset, count: 56)
            guard zip64End.uint32(at: 0) == Self.zip64EndSignature else { throw Error.damaged }
            count = zip64End.uint64(at: 32)
            directorySize = zip64End.uint64(at: 40)
            directoryOffset = zip64End.uint64(at: 48)
        }

        // Each entry takes at least 46 bytes, which bounds a forged count.
        guard directorySize <= fileSize, count <= directorySize / 46 + 1 else { throw Error.damaged }
        let directory = try bytes(at: directoryOffset, count: Int(directorySize))
        var entries: [Entry] = []
        entries.reserveCapacity(Int(count))
        var position = 0
        for _ in 0..<count {
            guard position + 46 <= directory.count,
                  directory.uint32(at: position) == Self.centralHeaderSignature else { throw Error.damaged }
            let flags = directory.uint16(at: position + 8)
            let method = directory.uint16(at: position + 10)
            let crc = directory.uint32(at: position + 16)
            var compressedSize = UInt64(directory.uint32(at: position + 20))
            var size = UInt64(directory.uint32(at: position + 24))
            let nameLength = Int(directory.uint16(at: position + 28))
            let extraLength = Int(directory.uint16(at: position + 30))
            let commentLength = Int(directory.uint16(at: position + 32))
            var localOffset = UInt64(directory.uint32(at: position + 42))
            let nameStart = position + 46
            let extraStart = nameStart + nameLength
            let next = extraStart + extraLength + commentLength
            guard next <= directory.count else { throw Error.damaged }

            let nameData = directory.subdata(in: directory.startIndex + nameStart..<directory.startIndex + extraStart)
            // Bit 11 marks UTF-8; older tools wrote code page 437, of which
            // Latin-1 gets the ASCII right.
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""

            // The ZIP64 extra field holds, in order, whichever of the sizes
            // and offset didn't fit.
            var extra = extraStart
            while extra + 4 <= extraStart + extraLength {
                let id = directory.uint16(at: extra)
                let length = Int(directory.uint16(at: extra + 2))
                var field = extra + 4
                let fieldEnd = field + length
                guard fieldEnd <= extraStart + extraLength else { throw Error.damaged }
                if id == 0x0001 {
                    if size == 0xFFFF_FFFF, field + 8 <= fieldEnd { size = directory.uint64(at: field); field += 8 }
                    if compressedSize == 0xFFFF_FFFF, field + 8 <= fieldEnd {
                        compressedSize = directory.uint64(at: field)
                        field += 8
                    }
                    if localOffset == 0xFFFF_FFFF, field + 8 <= fieldEnd { localOffset = directory.uint64(at: field) }
                }
                extra = fieldEnd
            }

            entries.append(Entry(
                path: name.replacingOccurrences(of: "\\", with: "/"), method: method, flags: flags, crc32: crc,
                compressedSize: compressedSize, size: size, localHeaderOffset: localOffset
            ))
            position = next
        }
        return entries
    }

    /// Where an entry's contents start, past its local header, whose name
    /// and extra field can differ in length from the central directory's.
    private func dataOffset(of entry: Entry) throws -> UInt64 {
        let header = try bytes(at: entry.localHeaderOffset, count: 30)
        guard header.uint32(at: 0) == Self.localHeaderSignature else { throw Error.damaged }
        return entry.localHeaderOffset + 30 + UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
    }
}

/// The CRC-32 that ZIP checks each entry's contents against.
struct CRC32 {
    private(set) var value: UInt32 = 0

    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { crc, _ in crc & 1 == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1 }
    }

    mutating func update(_ buffer: UnsafeRawBufferPointer) {
        var crc = ~value
        Self.table.withUnsafeBufferPointer { table in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        value = ~crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        data.withUnsafeBytes { crc.update($0) }
        return crc.value
    }
}

extension Data {
    /// Little-endian integers, as ZIP records hold them, at an offset from
    /// the data's start.
    func uint16(at offset: Int) -> UInt16 {
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * $1) }
    }

    func uint64(at offset: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + offset + $1]) << (8 * $1) }
    }
}
