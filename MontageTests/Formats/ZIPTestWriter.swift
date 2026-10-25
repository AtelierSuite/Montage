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
                extra.appendDRP(littleEndian: UInt16(0x0001))
                extra.appendDRP(littleEndian: UInt16(24))
                extra.appendDRP(littleEndian: UInt64(file.contents.count))
                extra.appendDRP(littleEndian: UInt64(compressed.count))
                extra.appendDRP(littleEndian: offset)
            }
            let small32: (Int) -> UInt32 = { zip64 ? 0xFFFF_FFFF : UInt32($0) }

            output.appendDRP(littleEndian: UInt32(0x0403_4B50))
            output.appendDRP(littleEndian: UInt16(zip64 ? 45 : 20))
            output.appendDRP(littleEndian: UInt16(0x0800))
            output.appendDRP(littleEndian: method)
            output.appendDRP(littleEndian: UInt32(0))
            output.appendDRP(littleEndian: crc)
            output.appendDRP(littleEndian: small32(compressed.count))
            output.appendDRP(littleEndian: small32(file.contents.count))
            output.appendDRP(littleEndian: UInt16(name.count))
            output.appendDRP(littleEndian: UInt16(0))
            output.append(name)
            output.append(compressed)

            directory.appendDRP(littleEndian: UInt32(0x0201_4B50))
            directory.appendDRP(littleEndian: UInt16(zip64 ? 45 : 20))
            directory.appendDRP(littleEndian: UInt16(zip64 ? 45 : 20))
            directory.appendDRP(littleEndian: UInt16(0x0800))
            directory.appendDRP(littleEndian: method)
            directory.appendDRP(littleEndian: UInt32(0))
            directory.appendDRP(littleEndian: crc)
            directory.appendDRP(littleEndian: small32(compressed.count))
            directory.appendDRP(littleEndian: small32(file.contents.count))
            directory.appendDRP(littleEndian: UInt16(name.count))
            directory.appendDRP(littleEndian: UInt16(extra.count))
            directory.appendDRP(littleEndian: UInt16(0))
            directory.appendDRP(littleEndian: UInt16(0))
            directory.appendDRP(littleEndian: UInt16(0))
            directory.appendDRP(littleEndian: UInt32(0))
            directory.appendDRP(littleEndian: zip64 ? 0xFFFF_FFFF : UInt32(offset))
            directory.append(name)
            directory.append(extra)
        }
        let directoryOffset = UInt64(output.count)
        output.append(directory)
        if zip64 {
            let recordOffset = UInt64(output.count)
            output.appendDRP(littleEndian: UInt32(0x0606_4B50))
            output.appendDRP(littleEndian: UInt64(44))
            output.appendDRP(littleEndian: UInt16(45))
            output.appendDRP(littleEndian: UInt16(45))
            output.appendDRP(littleEndian: UInt32(0))
            output.appendDRP(littleEndian: UInt32(0))
            output.appendDRP(littleEndian: UInt64(files.count))
            output.appendDRP(littleEndian: UInt64(files.count))
            output.appendDRP(littleEndian: UInt64(directory.count))
            output.appendDRP(littleEndian: directoryOffset)
            output.appendDRP(littleEndian: UInt32(0x0706_4B50))
            output.appendDRP(littleEndian: UInt32(0))
            output.appendDRP(littleEndian: recordOffset)
            output.appendDRP(littleEndian: UInt32(1))
        }
        output.appendDRP(littleEndian: UInt32(0x0605_4B50))
        output.appendDRP(littleEndian: UInt16(0))
        output.appendDRP(littleEndian: UInt16(0))
        output.appendDRP(littleEndian: zip64 ? 0xFFFF : UInt16(files.count))
        output.appendDRP(littleEndian: zip64 ? 0xFFFF : UInt16(files.count))
        output.appendDRP(littleEndian: zip64 ? 0xFFFF_FFFF : UInt32(directory.count))
        output.appendDRP(littleEndian: zip64 ? 0xFFFF_FFFF : UInt32(directoryOffset))
        output.appendDRP(littleEndian: UInt16(0))
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
    mutating func appendDRP<Value: FixedWidthInteger>(littleEndian value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendDRP<Value: FixedWidthInteger>(bigEndian value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
