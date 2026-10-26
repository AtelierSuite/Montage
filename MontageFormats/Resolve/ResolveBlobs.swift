import Foundation

/// The binary values Resolve writes into its project XML as hex text.
///
/// None of this is documented by Blackmagic. The layouts here are the ones
/// that independent open-source readers have measured on real exports and
/// agree on (see the findings on issue #36); anything they don't agree on,
/// or haven't decoded, isn't read, and its absence is reported instead.
enum ResolveBlobs {
    enum Failure: Error, Equatable {
        case malformed
        /// A zstd frame that needs a dictionary, which Resolve doesn't use.
        case compressed
    }

    // MARK: - Hex

    /// Hex text as bytes; nil if it isn't hex, or is cut off mid-byte.
    static func hex(_ text: String) -> Data? {
        let digits = text.utf8.filter { !($0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09) }
        guard digits.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(digits.count / 2)
        var high: UInt8?
        for digit in digits {
            let value: UInt8
            switch digit {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): value = digit - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): value = digit - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): value = digit - UInt8(ascii: "A") + 10
            default: return nil
            }
            if let first = high {
                bytes.append(first << 4 | value)
                high = nil
            } else {
                high = value
            }
        }
        return Data(bytes)
    }

    // MARK: - Frame counts

    /// A frame count as `<Start>`, `<Duration>` and `<In>` write it: whole
    /// frames, which Resolve 20 and later may follow with "|" and a
    /// little-endian double, the part of a frame left over.
    static func frames(_ text: String?) -> (whole: Int64, fraction: Double)? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let parts = text.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let whole = Int64(parts[0]) ?? Double(parts[0]).flatMap({ $0.isFinite && abs($0) < 9e15 ? Int64($0) : nil })
        else { return nil }
        guard parts.count == 2 else { return (whole, 0) }
        guard let bytes = hex(String(parts[1])), bytes.count == 8 else { return nil }
        let fraction = Double(bitPattern: bytes.littleEndianInteger(at: 0) ?? 0)
        guard fraction >= 0, fraction < 1 else { return nil }
        return (whole, fraction)
    }

    // MARK: - Fixed-size values

    /// `FrameRate` and `MediaFrameRate`: a little-endian double, then eight
    /// bytes that aren't read.
    static func frameRate(_ data: Data) -> Double? {
        guard data.count == 16, let bits: UInt64 = data.littleEndianInteger(at: 0) else { return nil }
        let rate = Double(bitPattern: bits)
        return rate.isFinite && rate > 0 && rate <= 1000 ? rate : nil
    }

    /// `Resolution`: the width and height, each a big-endian 64-bit number.
    static func resolution(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count == 16, let width: UInt64 = data.bigEndianInteger(at: 0),
              let height: UInt64 = data.bigEndianInteger(at: 8),
              (1...100_000).contains(width), (1...100_000).contains(height) else { return nil }
        return (Int(width), Int(height))
    }

    /// `MediaExtents`: where the timeline starts and how long it is, in
    /// seconds, as two little-endian doubles.
    static func extents(_ data: Data) -> (start: Double, duration: Double)? {
        guard data.count == 16, let start: UInt64 = data.littleEndianInteger(at: 0),
              let duration: UInt64 = data.littleEndianInteger(at: 8) else { return nil }
        let values = (Double(bitPattern: start), Double(bitPattern: duration))
        return values.0.isFinite && values.1.isFinite && abs(values.0) < 1e9 ? values : nil
    }

    // MARK: - Keyed dictionaries

    /// A value in a keyed dictionary.
    enum Value: Equatable {
        case bool(Bool)
        case integer(Int64)
        case double(Double)
        case string(String)
        case bytes(Data)
        case list([Value])
        case map([String: Value])
        case null
        /// A value of a kind that's read past but not kept, such as a date.
        case other

        var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
        var double: Double? { if case .double(let value) = self { value } else { nil } }
        var string: String? { if case .string(let value) = self { value } else { nil } }
        var bytes: Data? { if case .bytes(let value) = self { value } else { nil } }
    }

    /// What appears to be Qt's serialization of a map of variants: a header
    /// word of 1, a count, then for each entry a UTF-16 key and a typed
    /// value. Used for `Time`, `Geometry` and small `FieldsBlob`s.
    static func keyedDictionary(_ data: Data) throws -> [(key: String, value: Value)] {
        var reader = ByteReader(data)
        guard try reader.uint32() == 1 else { throw Failure.malformed }
        let count = try reader.uint32()
        guard count <= UInt32(data.count) else { throw Failure.malformed }
        var entries: [(key: String, value: Value)] = []
        for _ in 0..<count {
            let key = try reader.qString() ?? ""
            entries.append((key, try reader.qVariant(depth: 0)))
        }
        return entries
    }

    // MARK: - Messages

    /// The protocol buffer inside an envelope, `[version][length][codec]`
    /// and the payload, whose codec byte is 0x80 for a plain message or
    /// 0x81 for one in a zstd frame. A version of 2 with no codec byte, as
    /// inside a marker, holds a plain message too.
    static func message(_ data: Data) throws -> Data {
        var reader = ByteReader(data)
        let version = try reader.uint32()
        let length = Int(try reader.uint32())
        guard length == data.count - 8 else { throw Failure.malformed }
        if version == 2, data.count > 8, data[data.startIndex + 8] != 0x80, data[data.startIndex + 8] != 0x81 {
            return data.subdata(in: (data.startIndex + 8)..<data.endIndex)
        }
        let codec = try reader.uint8()
        let payload = data.subdata(in: (data.startIndex + 9)..<data.endIndex)
        switch codec {
        case 0x80: return payload
        case 0x81: return try zstd(payload)
        default: throw Failure.malformed
        }
    }

    /// A zstd frame's contents (see `ResolveZstd`).
    static func zstd(_ frame: Data, maximumSize: Int = 64 * 1024 * 1024) throws -> Data {
        try ResolveZstd.decompress(frame, maximumSize: maximumSize)
    }

    /// One field of a protocol buffer, read without its schema, which is
    /// Blackmagic's and private.
    struct Field: Equatable {
        var number: Int
        var varint: UInt64?
        var bytes: Data?

        var text: String? { bytes.flatMap { String(data: $0, encoding: .utf8) } }
    }

    static func protobuf(_ data: Data) throws -> [Field] {
        var reader = ByteReader(data)
        var fields: [Field] = []
        while !reader.isAtEnd {
            let key = try reader.varint()
            let number = Int(key >> 3)
            guard number > 0, fields.count < 1_000_000 else { throw Failure.malformed }
            switch key & 7 {
            case 0: fields.append(Field(number: number, varint: try reader.varint()))
            case 1: fields.append(Field(number: number, bytes: try reader.bytes(8)))
            case 2:
                let length = try reader.varint()
                guard length <= UInt64(Int.max) else { throw Failure.malformed }
                fields.append(Field(number: number, bytes: try reader.bytes(Int(length))))
            case 5: fields.append(Field(number: number, bytes: try reader.bytes(4)))
            default: throw Failure.malformed
            }
        }
        return fields
    }

    // MARK: - What's in them

    /// A media file's path from a media pool clip's `Clip` value: its
    /// folder in field 1 and its name in field 2.
    static func mediaPath(fromClip data: Data) throws -> String? {
        let fields = try protobuf(try message(data))
        let folder = fields.first { $0.number == 1 }?.text ?? ""
        let name = fields.first { $0.number == 2 }?.text ?? ""
        guard !name.isEmpty else { return folder.isEmpty ? nil : folder }
        guard !folder.isEmpty else { return name }
        if folder.hasSuffix("/") || folder.hasSuffix("\\") { return folder + name }
        return folder + (folder.contains("\\") && !folder.contains("/") ? "\\" : "/") + name
    }

    struct Marker: Equatable {
        /// From the start of the timeline, or of the clip it's on.
        var frame: Int64
        var name: String
        var note: String
    }

    /// The markers in a lockable blob's `FieldsBlob`: a keyed dictionary
    /// whose `BlobData` is a message listing them, each a frame and, in an
    /// envelope of its own, a colour, a note, a duration and a name.
    static func markers(fromFieldsBlob data: Data) throws -> [Marker] {
        guard let blob = try keyedDictionary(data).first(where: { $0.key == "BlobData" })?.value.bytes else {
            throw Failure.malformed
        }
        var markers: [Marker] = []
        for list in try protobuf(try message(blob)) where list.number == 2 {
            guard let listBytes = list.bytes else { throw Failure.malformed }
            for entry in try protobuf(listBytes) where entry.number == 1 {
                guard let entryBytes = entry.bytes else { throw Failure.malformed }
                let parts = try protobuf(entryBytes)
                guard let frame = parts.first(where: { $0.number == 1 })?.varint,
                      let body = parts.first(where: { $0.number == 2 })?.bytes,
                      let detail = try protobuf(try message(body)).first(where: { $0.number == 1 })?.bytes else {
                    throw Failure.malformed
                }
                let strings = try protobuf(detail).filter { $0.number == 3 }.map { $0.text ?? "" }
                markers.append(Marker(
                    frame: Int64(clamping: frame), name: strings.count > 2 ? strings[2] : "",
                    note: strings.first ?? ""
                ))
            }
        }
        return markers
    }

    // MARK: - Reading

    struct ByteReader {
        private let data: Data
        private var offset: Int

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool { offset >= data.endIndex }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, data.endIndex - offset >= count else { throw Failure.malformed }
            offset += count
        }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, data.endIndex - offset >= count else { throw Failure.malformed }
            defer { offset += count }
            return data.subdata(in: offset..<(offset + count))
        }

        mutating func uint8() throws -> UInt8 {
            guard offset < data.endIndex else { throw Failure.malformed }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func uint32() throws -> UInt32 {
            try bigEndian()
        }

        mutating func uint32LittleEndian() throws -> UInt32 {
            let value: UInt32 = try bigEndian()
            return value.byteSwapped
        }

        mutating func bigEndian<Value: FixedWidthInteger>() throws -> Value {
            let size = MemoryLayout<Value>.size
            guard data.endIndex - offset >= size else { throw Failure.malformed }
            var value: Value = 0
            for index in 0..<size { value = value << 8 | Value(data[offset + index]) }
            offset += size
            return value
        }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                let byte = try uint8()
                guard shift < 64 else { throw Failure.malformed }
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        /// A length in bytes, all ones for none, then UTF-16 big-endian.
        mutating func qString() throws -> String? {
            let length = try uint32()
            if length == 0xFFFF_FFFF { return nil }
            guard length % 2 == 0 else { throw Failure.malformed }
            let bytes = try bytes(Int(length))
            guard let string = String(data: bytes, encoding: .utf16BigEndian) else { throw Failure.malformed }
            return string
        }

        mutating func qVariant(depth: Int) throws -> Value {
            guard depth < 32 else { throw Failure.malformed }
            let type = try uint32()
            _ = try uint8()
            switch type {
            case 0x01: return .bool(try uint8() != 0)
            case 0x02: return .integer(Int64(Int32(bitPattern: try bigEndian())))
            case 0x03: return .integer(Int64(try bigEndian() as UInt32))
            case 0x04: return .integer(try bigEndian())
            case 0x05: return .integer(Int64(clamping: try bigEndian() as UInt64))
            case 0x06, 0x87: return .double(Double(bitPattern: try bigEndian()))
            case 0x07:
                try skip(2)
                return .other
            case 0x0A: return try qString().map(Value.string) ?? .null
            case 0x0C:
                let length = try uint32()
                return length == 0xFFFF_FFFF ? .null : .bytes(try bytes(Int(length)))
            case 0x10:
                try skip(9)
                return .other
            case 0x08:
                let count = try uint32()
                guard count <= UInt32(data.count) else { throw Failure.malformed }
                var map: [String: Value] = [:]
                for _ in 0..<count { map[try qString() ?? ""] = try qVariant(depth: depth + 1) }
                return .map(map)
            case 0x09, 0x0B:
                let count = try uint32()
                guard count <= UInt32(data.count) else { throw Failure.malformed }
                var list: [Value] = []
                for _ in 0..<count {
                    list.append(type == 0x0B ? (try qString().map(Value.string) ?? .null) : try qVariant(depth: depth + 1))
                }
                return .list(list)
            default:
                throw Failure.malformed
            }
        }
    }
}

extension Data {
    fileprivate func littleEndianInteger<Value: FixedWidthInteger>(at offset: Int) -> Value? {
        bigEndianInteger(at: offset).map { (value: Value) in value.byteSwapped }
    }

    fileprivate func bigEndianInteger<Value: FixedWidthInteger>(at offset: Int) -> Value? {
        let size = MemoryLayout<Value>.size
        guard offset >= 0, count - offset >= size else { return nil }
        var value: Value = 0
        for index in 0..<size { value = value << 8 | Value(self[startIndex + offset + index]) }
        return value
    }
}
