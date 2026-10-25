import Compression
import Foundation
@testable import MontageFormats

/// Writes small ZIP archives at test time, stored or deflated, optionally
/// with ZIP64 records, to read back.
struct ZIPTestWriter {
    struct File {
        var name: String
        var contents: Data
        var deflated = true
    }

    var files: [File] = []
    /// Writes ZIP64 sizes, offsets and end records even where they'd fit.
    var zip64 = false

    mutating func add(_ name: String, _ contents: String, deflated: Bool = true) {
        files.append(File(name: name, contents: Data(contents.utf8), deflated: deflated))
    }

    mutating func add(_ name: String, data: Data, deflated: Bool = true) {
        files.append(File(name: name, contents: data, deflated: deflated))
    }

    func archive() -> Data {
        var output = Data()
        var directory = Data()
        for file in files {
            let compressed = file.deflated ? Self.deflate(file.contents) : file.contents
            let method: UInt16 = file.deflated ? 8 : 0
            let crc = ResolveZIPArchive.crc32(file.contents)
            let name = Data(file.name.utf8)
            let offset = UInt64(output.count)

            var extra = Data()
            if zip64 {
                extra.append(le: UInt16(0x0001))
                extra.append(le: UInt16(24))
                extra.append(le: UInt64(file.contents.count))
                extra.append(le: UInt64(compressed.count))
                extra.append(le: offset)
            }
            let small32: (Int) -> UInt32 = { zip64 ? 0xFFFF_FFFF : UInt32($0) }

            output.append(le: UInt32(0x0403_4B50))
            output.append(le: UInt16(zip64 ? 45 : 20))
            output.append(le: UInt16(0x0800))
            output.append(le: method)
            output.append(le: UInt32(0))
            output.append(le: crc)
            output.append(le: small32(compressed.count))
            output.append(le: small32(file.contents.count))
            output.append(le: UInt16(name.count))
            output.append(le: UInt16(0))
            output.append(name)
            output.append(compressed)

            directory.append(le: UInt32(0x0201_4B50))
            directory.append(le: UInt16(zip64 ? 45 : 20))
            directory.append(le: UInt16(zip64 ? 45 : 20))
            directory.append(le: UInt16(0x0800))
            directory.append(le: method)
            directory.append(le: UInt32(0))
            directory.append(le: crc)
            directory.append(le: small32(compressed.count))
            directory.append(le: small32(file.contents.count))
            directory.append(le: UInt16(name.count))
            directory.append(le: UInt16(extra.count))
            directory.append(le: UInt16(0))
            directory.append(le: UInt16(0))
            directory.append(le: UInt16(0))
            directory.append(le: UInt32(0))
            directory.append(le: zip64 ? 0xFFFF_FFFF : UInt32(offset))
            directory.append(name)
            directory.append(extra)
        }
        let directoryOffset = UInt64(output.count)
        output.append(directory)
        if zip64 {
            let recordOffset = UInt64(output.count)
            output.append(le: UInt32(0x0606_4B50))
            output.append(le: UInt64(44))
            output.append(le: UInt16(45))
            output.append(le: UInt16(45))
            output.append(le: UInt32(0))
            output.append(le: UInt32(0))
            output.append(le: UInt64(files.count))
            output.append(le: UInt64(files.count))
            output.append(le: UInt64(directory.count))
            output.append(le: directoryOffset)
            output.append(le: UInt32(0x0706_4B50))
            output.append(le: UInt32(0))
            output.append(le: recordOffset)
            output.append(le: UInt32(1))
        }
        output.append(le: UInt32(0x0605_4B50))
        output.append(le: UInt16(0))
        output.append(le: UInt16(0))
        output.append(le: zip64 ? 0xFFFF : UInt16(files.count))
        output.append(le: zip64 ? 0xFFFF : UInt16(files.count))
        output.append(le: zip64 ? 0xFFFF_FFFF : UInt32(directory.count))
        output.append(le: zip64 ? 0xFFFF_FFFF : UInt32(directoryOffset))
        output.append(le: UInt16(0))
        return output
    }

    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data([0x03, 0x00]) }
        let capacity = data.count + 1024
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        return output.prefix(written)
    }
}

extension Data {
    mutating func append<Value: FixedWidthInteger>(le value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append<Value: FixedWidthInteger>(be value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
