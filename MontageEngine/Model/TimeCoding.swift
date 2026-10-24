import CoreMedia

// Times are written as exact rationals, "value/timescale", rather than as
// seconds: a frame at 30000/1001 fps has no exact decimal, and rounding it
// would drift a cut off its frame. CMTime isn't Codable itself, so the
// model's types code their times through these.

extension KeyedEncodingContainer {
    mutating func encode(_ time: CMTime, forKey key: Key) throws {
        guard time.isNumeric else {
            throw EncodingError.invalidValue(time, .init(codingPath: codingPath + [key], debugDescription: "Not a numeric time"))
        }
        try encode("\(time.value)/\(time.timescale)", forKey: key)
    }

    mutating func encode(_ range: CMTimeRange, forKey key: Key) throws {
        var container = nestedContainer(keyedBy: TimeRangeKeys.self, forKey: key)
        try container.encode(range.start, forKey: .start)
        try container.encode(range.duration, forKey: .duration)
    }
}

extension KeyedDecodingContainer {
    func decode(_ type: CMTime.Type, forKey key: Key) throws -> CMTime {
        let string = try decode(String.self, forKey: key)
        let parts = string.split(separator: "/")
        guard parts.count == 2, let value = Int64(parts[0]), let timescale = Int32(parts[1]), timescale > 0 else {
            throw DecodingError.dataCorruptedError(forKey: key, in: self, debugDescription: "Not a time: \(string)")
        }
        return CMTime(value: value, timescale: timescale)
    }

    func decode(_ type: CMTimeRange.Type, forKey key: Key) throws -> CMTimeRange {
        let container = try nestedContainer(keyedBy: TimeRangeKeys.self, forKey: key)
        return CMTimeRange(
            start: try container.decode(CMTime.self, forKey: .start),
            duration: try container.decode(CMTime.self, forKey: .duration)
        )
    }
}

private enum TimeRangeKeys: String, CodingKey {
    case start, duration
}
