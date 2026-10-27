import Compression
import Foundation

/// Gzipped data, read out uncompressed a buffer at a time, so a file that's
/// hundreds of megabytes once expanded never has to be in memory whole.
///
/// The gzip wrapper (RFC 1952) is read here; the DEFLATE stream inside it is
/// left to the Compression framework, whose `COMPRESSION_ZLIB` is raw
/// DEFLATE. The trailer's checksum and length are checked once the stream
/// ends, so a file that's damaged or cut short is an error rather than a
/// project with its end missing. A file of several gzip members, one after
/// another, reads as their data joined, and what follows the last member
/// that isn't another, such as padding, is passed over, as gzip does.
final class GzipInputStream: InputStream {
    /// Whether data starts as gzip does.
    static func isGzip(_ data: Data) -> Bool {
        data.count >= 2 && data[data.startIndex] == 0x1f && data[data.startIndex + 1] == 0x8b
    }

    /// Why the data couldn't be read, once it couldn't.
    private(set) var failure: GzipError?

    private let input: UnsafeMutableRawBufferPointer
    private var stream = compression_stream(
        dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil
    )
    private var isStreamReady = false
    private var status: Stream.Status = .notOpen
    private var crc = GzipCRC32()
    private var length: UInt32 = 0
    /// Where the current member's DEFLATE stream starts.
    private var memberStart = 0

    init(gzipped data: Data) {
        let input = UnsafeMutableRawBufferPointer.allocate(byteCount: max(data.count, 1), alignment: 1)
        data.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { input.baseAddress!.copyMemory(from: base, byteCount: bytes.count) }
        }
        self.input = input
        self.count = data.count
        super.init(data: Data())
    }

    private let count: Int

    deinit {
        if isStreamReady { compression_stream_destroy(&stream) }
        input.deallocate()
    }

    // MARK: - InputStream

    override func open() {
        guard status == .notOpen else { return }
        status = .open
        startMember(at: 0)
    }

    /// Starts reading the member whose header is at `offset`.
    private func startMember(at offset: Int) {
        if isStreamReady {
            compression_stream_destroy(&stream)
            isStreamReady = false
        }
        guard let start = headerEnd(at: offset) else { return fail(.damaged) }
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return fail(.damaged)
        }
        isStreamReady = true
        stream.src_ptr = UnsafePointer(input.baseAddress!.assumingMemoryBound(to: UInt8.self) + start)
        stream.src_size = count - start
        memberStart = start
        crc = GzipCRC32()
        length = 0
    }

    override func close() {
        status = .closed
    }

    override var streamStatus: Stream.Status { status }

    override var streamError: Error? { failure }

    override var hasBytesAvailable: Bool { status == .open || status == .notOpen }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength length: Int) -> Int {
        if status == .notOpen { open() }
        while true {
            guard status == .open, length > 0 else { return status == .error ? -1 : 0 }
            stream.dst_ptr = buffer
            stream.dst_size = length
            // All the input is there from the start, so a pass that can't
            // finish the stream means it was cut short.
            let result = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
            let produced = length - stream.dst_size
            crc.update(UnsafeRawBufferPointer(start: buffer, count: produced))
            self.length &+= UInt32(truncatingIfNeeded: produced)
            switch result {
            case COMPRESSION_STATUS_OK:
                if produced == 0 {
                    fail(.damaged)
                    return -1
                }
            case COMPRESSION_STATUS_END:
                guard let end = trailerEnd() else {
                    fail(.damaged)
                    return -1
                }
                if byte(end) == 0x1f, byte(end + 1) == 0x8b {
                    startMember(at: end)
                    // Nothing yet, which would read as the end.
                    if produced == 0 { continue }
                } else {
                    status = .atEnd
                }
            default:
                fail(.damaged)
                return -1
            }
            return produced
        }
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>, length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? { nil }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool { false }

    override func schedule(in aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    override func remove(from aRunLoop: RunLoop, forMode mode: RunLoop.Mode) {}

    // MARK: - Wrapper

    private func fail(_ error: GzipError) {
        failure = error
        status = .error
    }

    private func byte(_ offset: Int) -> UInt8? {
        offset < count ? input[offset] : nil
    }

    /// Where the DEFLATE stream after the header at `start` begins, or nil
    /// if it isn't a gzip header Compression can read past.
    private func headerEnd(at start: Int) -> Int? {
        // Magic, then DEFLATE as the method, then flags.
        guard byte(start) == 0x1f, byte(start + 1) == 0x8b, byte(start + 2) == 8, let flags = byte(start + 3) else {
            return nil
        }
        var offset = start + 10
        if flags & 0x04 != 0 {
            guard let low = byte(offset), let high = byte(offset + 1) else { return nil }
            offset += 2 + Int(low) + Int(high) << 8
        }
        // The file's name, then a comment, each ended by a zero.
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while let value = byte(offset), value != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        return offset < count ? offset : nil
    }

    /// Where the member's trailer, its checksum and length, ends, or nil
    /// if they aren't the data's. Compression may read ahead past the
    /// stream's end, so where it stopped doesn't say where the trailer is,
    /// only that it's no further on: it's looked for back from there.
    private func trailerEnd() -> Int? {
        func word(_ at: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | UInt32(input[at + $1]) << (8 * UInt32($1)) }
        }
        let consumed = count - stream.src_size
        var offset = min(consumed, count - 8)
        while offset > memberStart {
            if word(offset) == crc.value, word(offset + 4) == length { return offset + 8 }
            offset -= 1
        }
        return nil
    }
}

/// Why gzipped data couldn't be read.
enum GzipError: Error, Equatable {
    /// Not gzip, damaged, or cut short.
    case damaged
}

/// The CRC-32 gzip ends with, made a buffer at a time.
struct GzipCRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        (0..<8).reduce(UInt32(index)) { value, _ in value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
    }

    private var state: UInt32 = 0xFFFF_FFFF

    var value: UInt32 { state ^ 0xFFFF_FFFF }

    mutating func update(_ bytes: UnsafeRawBufferPointer) {
        var crc = state
        Self.table.withUnsafeBufferPointer { table in
            for byte in bytes {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        state = crc
    }
}
