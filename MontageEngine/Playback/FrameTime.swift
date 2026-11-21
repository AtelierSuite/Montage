import CoreMedia

/// Times on the project's frame grid: frame numbers, steps of one frame, and
/// timecode.
public struct FrameTime: Equatable, Sendable {
    /// How long each frame lasts, as in `ProjectSettings.frameDuration`.
    public var frameDuration: CMTime

    public init(frameDuration: CMTime) {
        self.frameDuration = frameDuration.isNumeric && frameDuration > .zero ? frameDuration : CMTime(value: 1, timescale: 30)
    }

    /// The frame showing at a time: the last one starting at or before it.
    public func frame(at time: CMTime) -> Int64 {
        guard time.isNumeric, time > .zero else { return 0 }
        // Exact rational division, so 1001/30000 frames don't drift.
        let numerator = time.value * Int64(frameDuration.timescale)
        let denominator = frameDuration.value * Int64(time.timescale)
        return numerator / denominator
    }

    /// When a frame starts.
    public func time(ofFrame frame: Int64) -> CMTime {
        CMTime(value: frameDuration.value * frame, timescale: frameDuration.timescale)
    }

    /// The start of the frame showing at a time.
    public func snapped(_ time: CMTime) -> CMTime {
        self.time(ofFrame: frame(at: time))
    }

    /// The frame boundary nearest a time, either side of zero; halfway
    /// rounds up.
    public func nearest(_ time: CMTime) -> CMTime {
        boundary(time, rounding: .toNearestOrAwayFromZero)
    }

    /// The last frame boundary at or before a time, either side of zero.
    public func floor(_ time: CMTime) -> CMTime {
        boundary(time, rounding: .down)
    }

    /// The first frame boundary at or after a time, either side of zero.
    public func ceiling(_ time: CMTime) -> CMTime {
        boundary(time, rounding: .up)
    }

    public func isOnFrame(_ time: CMTime) -> Bool {
        floor(time) == time
    }

    private func boundary(_ time: CMTime, rounding rule: FloatingPointRoundingRule) -> CMTime {
        guard time.isNumeric else { return time }
        let (numerator, overflowA) = time.value.multipliedReportingOverflow(by: Int64(frameDuration.timescale))
        let (denominator, overflowB) = frameDuration.value.multipliedReportingOverflow(by: Int64(time.timescale))
        guard !overflowA, !overflowB else {
            return self.time(ofFrame: Int64((time.seconds / frameDuration.seconds).rounded(rule)))
        }
        var frame = numerator / denominator
        var remainder = numerator % denominator
        if remainder < 0 {
            frame -= 1
            remainder += denominator
        }
        switch rule {
        case .down: break
        case .up: if remainder > 0 { frame += 1 }
        default: if remainder * 2 >= denominator { frame += 1 }
        }
        return self.time(ofFrame: frame)
    }

    /// Frames per second as timecode counts them: 30 for 29.97.
    public var timecodeRate: Int64 {
        max(1, Int64((1 / frameDuration.seconds).rounded()))
    }

    /// The time as `HH:MM:SS:FF`, counting frames at the timecode rate
    /// without dropping any.
    public func timecode(_ time: CMTime) -> String {
        let frame = frame(at: time)
        let rate = timecodeRate
        let frames = frame % rate
        let seconds = frame / rate
        func pad(_ value: Int64) -> String {
            value < 10 ? "0\(value)" : "\(value)"
        }
        return "\(pad(seconds / 3600)):\(pad(seconds / 60 % 60)):\(pad(seconds % 60)):\(pad(frames))"
    }
}
