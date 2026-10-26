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
        case double(Int, Double)
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
            case .double(let number, let value):
                varint(UInt64(number << 3 | 1), into: &data)
                data.appendDRP(littleEndian: value.bitPattern)
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

    /// An envelope around a zstd frame made elsewhere, such as by the `zstd` tool.
    static func envelope(zstdFrame frame: Data, version: UInt32 = 2) -> Data {
        var data = Data()
        data.appendDRP(bigEndian: version)
        data.appendDRP(bigEndian: UInt32(frame.count + 1))
        data.append(0x81)
        data.append(frame)
        return data
    }

    // MARK: - Clip settings

    /// A parameter's value, as a filter's parameter holds it.
    enum FilterValue {
        case double(Double)
        case enumeration(UInt64)
        /// A number, as it's stored: zigzag encoded.
        case integer(UInt64)
        case flag(Bool)
        case pair(Double, Double)
    }

    struct FilterKeyframe {
        var frame: Int64
        var value: Double
        /// Curved keyframes carry 48 bytes of handles.
        var curved = false
    }

    /// A parameter of a filter: its number in field 1, its value in field 3
    /// and its keyframes in field 10.
    static func parameter(_ number: Int, _ value: FilterValue? = nil, keyframes: [FilterKeyframe] = []) -> Data {
        var fields: [Field] = [.varint(1, UInt64(number))]
        if let value {
            let inner: Field
            switch value {
            case .double(let value): inner = .double(2, value)
            case .enumeration(let value): inner = .varint(4, value)
            case .integer(let value): inner = .varint(1, value)
            case .flag(let value): inner = .varint(5, value ? 1 : 0)
            case .pair(let first, let second):
                var bytes = Data()
                bytes.appendDRP(bigEndian: first.bitPattern)
                bytes.appendDRP(bigEndian: second.bitPattern)
                inner = .bytes(7, bytes)
            }
            fields.append(.bytes(3, protobuf([.bytes(1, protobuf([inner]))])))
        }
        if !keyframes.isEmpty { fields.append(.bytes(10, keyframeList(keyframes))) }
        return protobuf(fields)
    }

    /// Keyframes as a parameter's field 10 holds them.
    static func keyframeList(_ keyframes: [FilterKeyframe]) -> Data {
        var records = Data()
        for keyframe in keyframes {
            let frame = UInt64(bitPattern: keyframe.frame)
            for index in 0..<6 { records.append(UInt8((frame >> (8 * index)) & 0xFF)) }
            records.append(keyframe.curved ? 0x0D : 0x0C)
            records.append(0)
            records.appendDRP(littleEndian: keyframe.value.bitPattern)
            if keyframe.curved { records.append(Data(repeating: 0x11, count: 48)) }
        }
        var data = Data()
        data.appendDRP(bigEndian: UInt32(bitPattern: -Int32(records.count)))
        data.append(records)
        return data
    }

    /// A filter: its type in field 1 and a field 9 for each of its
    /// parameters, empty for those at their defaults.
    static func filter(_ type: Int, _ parameters: [Data?]) -> Data {
        protobuf([.varint(1, UInt64(type)), .varint(7, 2)] + parameters.map { .bytes(9, $0 ?? Data()) })
    }

    /// An Open FX effect, which names its plugin.
    static func openFX(_ plugin: String) -> Data {
        let settings = protobuf([.varint(1, 5195353), .text(2, plugin), .text(3, "OfxImageEffectContextFilter")])
        let parameter = protobuf([.varint(1, 109), .varint(2, 0), .bytes(3, protobuf([.bytes(2, settings)]))])
        return protobuf([.varint(1, 50), .varint(3, 4), .varint(7, 20), .bytes(9, parameter)])
    }

    /// A clip's `EffectFiltersBA`.
    static func effectFilters(_ filters: [Data], zstd: Bool = true) -> Data {
        envelope(protobuf(filters.map { .bytes(1, $0) }), version: 2, zstd: zstd)
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

extension Data {
    fileprivate mutating func appendDRP<Value: FixedWidthInteger>(littleEndian value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func appendDRP<Value: FixedWidthInteger>(bigEndian value: Value) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
