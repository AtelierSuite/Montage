import Foundation
@testable import MontageFormats

/// Writes the binary values Resolve keeps in its XML, in the layouts
/// `ResolveBlobs` reads, to build projects at test time.
enum ResolveBlobWriter {
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func frameRate(_ rate: Double) -> Data {
        var data = Data()
        data.appendDRP(littleEndian: rate.bitPattern)
        data.appendDRP(littleEndian: UInt64(0))
        return data
    }

    static func resolution(width: Int, height: Int) -> Data {
        var data = Data()
        data.appendDRP(bigEndian: UInt64(width))
        data.appendDRP(bigEndian: UInt64(height))
        return data
    }

    static func extents(start: Double, duration: Double) -> Data {
        var data = Data()
        data.appendDRP(littleEndian: start.bitPattern)
        data.appendDRP(littleEndian: duration.bitPattern)
        return data
    }

    enum Value {
        case int32(Int32)
        case double(Double)
        case string(String)
        case bytes(Data)
    }

    static func keyedDictionary(_ entries: [(String, Value)]) -> Data {
        var data = Data()
        data.appendDRP(bigEndian: UInt32(1))
        data.appendDRP(bigEndian: UInt32(entries.count))
        for (key, value) in entries {
            qString(key, into: &data)
            switch value {
            case .int32(let number):
                data.appendDRP(bigEndian: UInt32(0x02))
                data.append(UInt8(0))
                data.appendDRP(bigEndian: number)
            case .double(let number):
                data.appendDRP(bigEndian: UInt32(0x06))
                data.append(UInt8(0))
                data.appendDRP(bigEndian: number.bitPattern)
            case .string(let string):
                data.appendDRP(bigEndian: UInt32(0x0A))
                data.append(UInt8(0))
                qString(string, into: &data)
            case .bytes(let bytes):
                data.appendDRP(bigEndian: UInt32(0x0C))
                data.append(UInt8(0))
                data.appendDRP(bigEndian: UInt32(bytes.count))
                data.append(bytes)
            }
        }
        return data
    }

    private static func qString(_ string: String, into data: inout Data) {
        let utf16 = string.data(using: .utf16BigEndian)!
        data.appendDRP(bigEndian: UInt32(utf16.count))
        data.append(utf16)
    }

    // MARK: - Messages

    enum Field {
        case varint(Int, UInt64)
        case bytes(Int, Data)
        case text(Int, String)
    }

    static func protobuf(_ fields: [Field]) -> Data {
        var data = Data()
        for field in fields {
            switch field {
            case .varint(let number, let value):
                varint(UInt64(number << 3), into: &data)
                varint(value, into: &data)
            case .bytes(let number, let bytes):
                varint(UInt64(number << 3 | 2), into: &data)
                varint(UInt64(bytes.count), into: &data)
                data.append(bytes)
            case .text(let number, let text):
                varint(UInt64(number << 3 | 2), into: &data)
                varint(UInt64(text.utf8.count), into: &data)
                data.append(Data(text.utf8))
            }
        }
        return data
    }

    private static func varint(_ value: UInt64, into data: inout Data) {
        var value = value
        repeat {
            data.append(UInt8(value & 0x7F) | (value > 0x7F ? 0x80 : 0))
            value >>= 7
        } while value != 0
    }

    /// A zstd frame of raw blocks, as Resolve writes small values.
    static func zstdRaw(_ payload: Data) -> Data {
        var data = Data([0x28, 0xB5, 0x2F, 0xFD])
        // Single segment, four-byte content size.
        data.append(0xA0)
        data.appendDRP(littleEndian: UInt32(payload.count))
        let header = UInt32(payload.count) << 3 | 1
        data.append(UInt8(header & 0xFF))
        data.append(UInt8((header >> 8) & 0xFF))
        data.append(UInt8((header >> 16) & 0xFF))
        data.append(payload)
        return data
    }

    /// `[version][length][codec][payload]`, the payload zstd framed or not.
    static func envelope(_ message: Data, version: UInt32 = 10001, zstd: Bool = true) -> Data {
        let payload = zstd ? zstdRaw(message) : message
        var data = Data()
        data.appendDRP(bigEndian: version)
        data.appendDRP(bigEndian: UInt32(payload.count + 1))
        data.append(zstd ? 0x81 : 0x80)
        data.append(payload)
        return data
    }

    /// A media pool clip's `Clip` value, naming its file.
    static func clip(folder: String, name: String) -> Data {
        envelope(protobuf([.text(1, folder), .text(2, name), .text(5, "H.264")]), version: 1, zstd: false)
    }

    /// A lockable blob's `FieldsBlob` listing markers.
    static func markers(_ markers: [(frame: UInt64, name: String, note: String)]) -> Data {
        let entries = markers.map { marker -> Data in
            let detail = protobuf([.varint(1, 2), .text(3, marker.note), .text(3, "1"), .text(3, marker.name)])
            let inner = protobuf([.bytes(1, detail)])
            var body = Data()
            body.appendDRP(bigEndian: UInt32(2))
            body.appendDRP(bigEndian: UInt32(inner.count))
            body.append(inner)
            return protobuf([.bytes(1, protobuf([.varint(1, marker.frame), .bytes(2, body)]))])
        }
        let list = protobuf([.bytes(2, entries.reduce(Data(), +))])
        return keyedDictionary([("BlobData", .bytes(envelope(list)))])
    }
}
