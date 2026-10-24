import CoreMedia
import Foundation

/// Times as interchange files write them.
enum InterchangeTime {
    /// A Final Cut time, a rational number of seconds such as "1001/30000s"
    /// or "5s", as the exact `CMTime` it stands for. Decimal seconds, which
    /// some other apps write, are read too, to the microsecond.
    static func parse(_ string: String?) -> CMTime? {
        guard var string = string?.trimmingCharacters(in: .whitespaces), !string.isEmpty else { return nil }
        if string.hasSuffix("s") { string.removeLast() }
        let parts = string.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2 {
            guard let value = Int64(parts[0]), let denominator = Int64(parts[1]), denominator > 0 else { return nil }
            return time(value, over: denominator)
        }
        if let value = Int64(string) { return CMTime(value: value, timescale: 1) }
        guard let seconds = Double(string), seconds.isFinite else { return nil }
        return CMTime(value: Int64((seconds * 1_000_000).rounded()), timescale: 1_000_000)
    }

    /// `value / denominator` seconds. A denominator too large for a
    /// timescale is reduced first, and only rounded if it still doesn't fit.
    static func time(_ value: Int64, over denominator: Int64) -> CMTime {
        let divisor = gcd(abs(value), denominator)
        var value = value / max(divisor, 1)
        var denominator = denominator / max(divisor, 1)
        if denominator > Int64(Int32.max) {
            let scale = Double(Int32.max) / Double(denominator)
            value = Int64((Double(value) * scale).rounded())
            denominator = Int64(Int32.max)
        }
        return CMTime(value: value, timescale: CMTimeScale(denominator))
    }

    /// A time the way Final Cut writes it: reduced, "1001/30000s", or "5s"
    /// for whole seconds.
    static func string(_ time: CMTime) -> String {
        guard time.isNumeric, time.value != 0 else { return "0s" }
        let divisor = gcd(abs(time.value), Int64(time.timescale))
        let value = time.value / divisor
        let denominator = Int64(time.timescale) / divisor
        return denominator == 1 ? "\(value)s" : "\(value)/\(denominator)s"
    }

    /// A time put onto the nearest frame of `frameDuration`, so a cut
    /// lands on a frame boundary as Final Cut expects.
    static func conformed(_ time: CMTime, to frameDuration: CMTime) -> CMTime {
        guard frameDuration.isNumeric, frameDuration > .zero, time.isNumeric else { return time }
        let count = (time.seconds / frameDuration.seconds).rounded()
        return frames(Int64(count), frameDuration: frameDuration)
    }

    /// The time of a count of frames, exactly.
    static func frames(_ count: Int64, frameDuration: CMTime) -> CMTime {
        time(count * frameDuration.value, over: Int64(frameDuration.timescale))
    }

    /// The length of a frame at a Final Cut 7 style rate: a whole-number
    /// timebase, slowed by 1000/1001 when it's an NTSC rate.
    static func frameDuration(timebase: Int64, ntsc: Bool) -> CMTime {
        guard timebase > 0 else { return CMTime(value: 1, timescale: 30) }
        return ntsc ? time(1001, over: timebase * 1000) : time(1, over: timebase)
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }
}

/// Why an interchange file couldn't be read or written.
public enum InterchangeError: LocalizedError, Equatable {
    /// Not well-formed XML; the parser's explanation, where it gave one.
    case unreadable(String?)
    /// XML, but not a format Montage reads.
    case unsupportedFormat
    /// A file of the right format with no timeline in it.
    case noTimeline

    public var errorDescription: String? {
        switch self {
        case .unreadable:
            String(localized: "Interchange.Error.Unreadable", bundle: #bundle)
        case .unsupportedFormat:
            String(localized: "Interchange.Error.UnsupportedFormat", bundle: #bundle)
        case .noTimeline:
            String(localized: "Interchange.Error.NoTimeline", bundle: #bundle)
        }
    }

    public var recoverySuggestion: String? {
        if case .unreadable(let reason?) = self { reason } else { nil }
    }
}
