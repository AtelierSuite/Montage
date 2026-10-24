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
