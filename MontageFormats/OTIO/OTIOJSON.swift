import CoreMedia
import Foundation

/// A JSON value as OpenTimelineIO writes it: objects keep the order their
/// keys were given in, with `OTIO_SCHEMA` first, and whole numbers of a
/// floating-point field are written with a point (`24.0`), as OTIO's own
/// Python and C++ writers do.
enum OTIOJSON: Equatable {
    case object([(String, OTIOJSON)])
    case array([OTIOJSON])
    case string(String)
    case double(Double)
    case integer(Int64)
    case bool(Bool)
    case null

    /// Where Montage's own metadata goes, beside other apps'.
    static let montageKey = "Montage"

    static func == (lhs: OTIOJSON, rhs: OTIOJSON) -> Bool {
        switch (lhs, rhs) {
        case (.object(let a), .object(let b)): a.map(\.0) == b.map(\.0) && a.map(\.1) == b.map(\.1)
        case (.array(let a), .array(let b)): a == b
        case (.string(let a), .string(let b)): a == b
        case (.double(let a), .double(let b)): a == b
        case (.integer(let a), .integer(let b)): a == b
        case (.bool(let a), .bool(let b)): a == b
        case (.null, .null): true
        default: false
        }
    }

    /// An object of one of OTIO's schemas, such as `Clip.2`.
    static func schema(_ schema: String, _ fields: [(String, OTIOJSON)]) -> OTIOJSON {
        .object([("OTIO_SCHEMA", .string(schema))] + fields)
    }

    /// A value read by `JSONSerialization`, such as Montage's own encoding
    /// of a clip, to write back out.
    init(_ value: Any) {
        switch value {
        case let dictionary as [String: Any]:
            self = .object(dictionary.keys.sorted().map { ($0, OTIOJSON(dictionary[$0]!)) })
        case let array as [Any]:
            self = .array(array.map(OTIOJSON.init))
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else if CFNumberIsFloatType(number) {
                self = .double(number.doubleValue)
            } else {
                self = .integer(number.int64Value)
            }
        default:
            self = .null
        }
    }

    // MARK: - Writing

    /// The value as indented JSON text.
    func data() -> Data {
        var text = ""
        write(to: &text, indent: 0)
        text += "\n"
        return Data(text.utf8)
    }

    private func write(to text: inout String, indent: Int) {
        let padding = String(repeating: "    ", count: indent + 1)
        let closing = String(repeating: "    ", count: indent)
        switch self {
        case .object(let fields):
            guard !fields.isEmpty else { text += "{}"; return }
            text += "{\n"
            for (index, (key, value)) in fields.enumerated() {
                text += padding + Self.quoted(key) + ": "
                value.write(to: &text, indent: indent + 1)
                text += index < fields.count - 1 ? ",\n" : "\n"
            }
            text += closing + "}"
        case .array(let values):
            guard !values.isEmpty else { text += "[]"; return }
            text += "[\n"
            for (index, value) in values.enumerated() {
                text += padding
                value.write(to: &text, indent: indent + 1)
                text += index < values.count - 1 ? ",\n" : "\n"
            }
            text += closing + "]"
        case .string(let string):
            text += Self.quoted(string)
        case .double(let number):
            text += Self.number(number)
        case .integer(let number):
            text += String(number)
        case .bool(let value):
            text += value ? "true" : "false"
        case .null:
            text += "null"
        }
    }

    /// A floating-point number, exactly, with a point even when whole; null
    /// for what JSON can't write.
    private static func number(_ number: Double) -> String {
        guard number.isFinite else { return "null" }
        if number == number.rounded(), abs(number) < 1e15 { return String(format: "%.1f", number) }
        return "\(number)"
    }

    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case let scalar where scalar.value < 0x20:
                result += String(format: "\\u%04x", scalar.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

// MARK: - Times

/// Times as OpenTimelineIO writes them: a `RationalTime` is a count (`value`)
/// of units that `rate` of fit in a second, both floating-point, so 29.97 fps
/// is written as 29.97002997… or as 23.976 for 23.976.
enum OTIOTime {
    /// The length of a frame at an OTIO rate: a whole number, or a whole
    /// number slowed by 1000/1001 for NTSC rates; nil for any other rate.
    static func frameDuration(rate: Double) -> CMTime? {
        guard rate.isFinite, rate > 0, rate <= 1_000_000 else { return nil }
        let whole = rate.rounded()
        if abs(rate - whole) < 0.0001 { return CMTime(value: 1, timescale: CMTimeScale(whole)) }
        let ntsc = (rate * 1.001).rounded()
        if abs(rate * 1.001 - ntsc) < 0.001 { return InterchangeTime.time(1001, over: Int64(ntsc) * 1000) }
        return nil
    }

    /// The rate a frame of `frameDuration` lasts at, as OTIO writes it.
    static func rate(frameDuration: CMTime) -> Double {
        guard frameDuration.isNumeric, frameDuration.value > 0 else { return 30 }
        return Double(frameDuration.timescale) / Double(frameDuration.value)
    }

    /// A `RationalTime`, as the exact time it stands for where its value is
    /// a whole number of frames at a frame rate, and to the microsecond
    /// otherwise.
    static func time(_ object: Any?) -> CMTime? {
        guard let object = object as? [String: Any],
              let value = (object["value"] as? NSNumber)?.doubleValue,
              let rate = (object["rate"] as? NSNumber)?.doubleValue,
              value.isFinite, rate.isFinite, rate > 0 else { return nil }
        if value == value.rounded(), abs(value) < 9e15, let frame = frameDuration(rate: rate),
           let time = InterchangeTime.frames(Int64(value), frameDuration: frame) {
            return time
        }
        let seconds = value / rate
        guard seconds.isFinite, abs(seconds) < 9e12 else { return nil }
        return CMTime(value: Int64((seconds * 1_000_000).rounded()), timescale: 1_000_000)
    }

    /// A `TimeRange`.
    static func range(_ object: Any?) -> CMTimeRange? {
        guard let object = object as? [String: Any],
              let start = time(object["start_time"]), let duration = time(object["duration"]) else { return nil }
        return CMTimeRange(start: start, duration: duration)
    }

    /// The rate a `RationalTime` is counted at.
    static func rate(of object: Any?) -> Double? {
        ((object as? [String: Any])?["rate"] as? NSNumber)?.doubleValue
    }

    /// A time as a `RationalTime`: a whole number of frames at the
    /// project's rate where it falls on a frame, and otherwise exactly, in
    /// its own timescale.
    static func json(_ time: CMTime, frameDuration: CMTime) -> OTIOJSON {
        let time = time.isNumeric ? time : .zero
        if frameDuration.isNumeric, frameDuration.value > 0 {
            // time / frame = (t.value * f.timescale) / (t.timescale * f.value)
            let numerator = time.value.multipliedReportingOverflow(by: Int64(frameDuration.timescale))
            let denominator = Int64(time.timescale).multipliedReportingOverflow(by: frameDuration.value)
            if !numerator.overflow, !denominator.overflow, denominator.partialValue != 0,
               numerator.partialValue % denominator.partialValue == 0 {
                return .schema("RationalTime.1", [
                    ("rate", .double(rate(frameDuration: frameDuration))),
                    ("value", .double(Double(numerator.partialValue / denominator.partialValue))),
                ])
            }
        }
        return .schema("RationalTime.1", [("rate", .double(Double(time.timescale))), ("value", .double(Double(time.value)))])
    }

    static func json(_ range: CMTimeRange, frameDuration: CMTime) -> OTIOJSON {
        .schema("TimeRange.1", [
            ("duration", json(range.duration, frameDuration: frameDuration)),
            ("start_time", json(range.start, frameDuration: frameDuration)),
        ])
    }
}
