import CoreMedia
import Foundation

/// A timecode as an EDL writes it, "01:00:02:12", with a semicolon before
/// the frames ("01:00:02;12") in drop frame.
struct EDLTimecode: Equatable {
    var hours: Int
    var minutes: Int
    var seconds: Int
    var frames: Int

    init(hours: Int, minutes: Int, seconds: Int, frames: Int) {
        self.hours = hours
        self.minutes = minutes
        self.seconds = seconds
        self.frames = frames
    }

    /// Reads "HH:MM:SS:FF", with any of `:`, `;`, `.` or `,` between the
    /// fields; nil for anything else.
    init?(_ string: some StringProtocol) {
        let fields = string.split(omittingEmptySubsequences: false) { ":;.,".contains($0) }
        guard fields.count == 4, fields.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCII) }),
              let hours = Int(fields[0]), let minutes = Int(fields[1]), let seconds = Int(fields[2]),
              let frames = Int(fields[3]), hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60,
              frames >= 0 else { return nil }
        self.init(hours: hours, minutes: minutes, seconds: seconds, frames: frames)
    }

    /// The count of frames from 00:00:00:00, at `rate`.
    func frameCount(at rate: EDLRate, dropFrame: Bool) -> Int {
        let base = rate.timecodeBase
        let totalMinutes = hours * 60 + minutes
        let count = (totalMinutes * 60 + seconds) * base + frames
        guard dropFrame, let drop = rate.droppedFramesPerMinute else { return count }
        return count - drop * (totalMinutes - totalMinutes / 10)
    }

    /// The timecode of a count of frames, wrapping at 24 hours as a deck's
    /// does.
    init(frameCount: Int, rate: EDLRate, dropFrame: Bool) {
        let base = rate.timecodeBase
        var count = frameCount
        if dropFrame, let drop = rate.droppedFramesPerMinute {
            let perTenMinutes = base * 600 - drop * 9
            let perMinute = base * 60 - drop
            let day = perTenMinutes * 6 * 24
            count = ((count % day) + day) % day
            let tens = count / perTenMinutes
            let remainder = count % perTenMinutes
            count += drop * 9 * tens + (remainder > drop ? drop * ((remainder - drop) / perMinute) : 0)
        } else {
            let day = base * 86400
            count = ((count % day) + day) % day
        }
        self.init(
            hours: count / (base * 3600), minutes: count / (base * 60) % 60, seconds: count / base % 60,
            frames: count % base
        )
    }

    func string(dropFrame: Bool) -> String {
        String(format: "%02d:%02d:%02d%@%02d", hours, minutes, seconds, dropFrame ? ";" : ":", frames)
    }
}

/// The rate an EDL's timecode counts frames at, which the file itself
/// doesn't say.
struct EDLRate: Equatable, Sendable {
    /// How long a frame lasts: 1001/30000 for 29.97.
    var frameDuration: CMTime
    /// The frames counted in each second of timecode: 30 for 29.97.
    var timecodeBase: Int

    init(frameDuration: CMTime) {
        self.frameDuration = frameDuration
        let rate = frameDuration.seconds > 0 ? 1 / frameDuration.seconds : 30
        timecodeBase = max(1, Int(rate.rounded()))
    }

    static let ntsc30 = EDLRate(frameDuration: CMTime(value: 1001, timescale: 30000))
    static let ntsc60 = EDLRate(frameDuration: CMTime(value: 1001, timescale: 60000))
    static let fps30 = EDLRate(frameDuration: CMTime(value: 1, timescale: 30))
    static let fps60 = EDLRate(frameDuration: CMTime(value: 1, timescale: 60))

    /// The rates media is commonly at, to put a probed rate onto.
    static let standard: [EDLRate] = [
        EDLRate(frameDuration: CMTime(value: 1001, timescale: 24000)), EDLRate(frameDuration: CMTime(value: 1, timescale: 24)),
        EDLRate(frameDuration: CMTime(value: 1, timescale: 25)), ntsc30, fps30,
        EDLRate(frameDuration: CMTime(value: 1, timescale: 50)), ntsc60, fps60,
    ]

    /// The standard rate nearest a probed one, if one is close.
    static func nearest(to framesPerSecond: Double) -> EDLRate? {
        standard.min { abs($0.framesPerSecond - framesPerSecond) < abs($1.framesPerSecond - framesPerSecond) }
            .flatMap { abs($0.framesPerSecond - framesPerSecond) < 0.05 ? $0 : nil }
    }

    var framesPerSecond: Double { 1 / frameDuration.seconds }

    /// Whether drop frame timecode can count this rate: only the NTSC rates
    /// of 29.97 and 59.94 drop.
    var canDropFrames: Bool { droppedFramesPerMinute != nil }

    /// The frame numbers skipped each minute but every tenth, in drop frame.
    var droppedFramesPerMinute: Int? {
        guard frameDuration.value == 1001, timecodeBase % 30 == 0 else { return nil }
        return timecodeBase / 15
    }

    /// The time of a count of frames.
    func time(_ frames: Int) -> CMTime {
        InterchangeTime.frames(Int64(frames), frameDuration: frameDuration) ?? .zero
    }

    /// A time as the nearest count of frames.
    func frames(_ time: CMTime) -> Int {
        guard time.isNumeric else { return 0 }
        return Int((time.seconds / frameDuration.seconds).rounded())
    }

    /// The rate as it's read out: "29.97", "30", "23.976".
    var displayString: String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter.string(from: NSNumber(value: (framesPerSecond * 1000).rounded() / 1000)) ?? "\(timecodeBase)"
    }
}
