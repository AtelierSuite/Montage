import CoreMedia

/// Changing a parameter at the playhead, as an inspector does.
extension Animatable {
    /// Whether there's a keyframe at exactly this time.
    public func hasKeyframe(at time: CMTime) -> Bool {
        keyframes.contains { $0.time == time }
    }

    /// Sets the parameter's value at a time. One that isn't keyframed takes
    /// the value throughout; a keyframed one gets a keyframe there, keeping
    /// the way any keyframe already there travels on.
    public mutating func set(_ newValue: Value, at time: CMTime) {
        guard isAnimated else {
            value = newValue
            return
        }
        let interpolation = keyframes.first { $0.time == time }?.interpolation ?? .linear
        setKeyframe(Keyframe(time: time, value: newValue, interpolation: interpolation))
    }

    /// Adds a keyframe at a time, holding the value the parameter has
    /// there, or takes away the one that's there. Taking away the last
    /// keyframe leaves the parameter at the value it had there throughout.
    public mutating func toggleKeyframe(at time: CMTime) {
        if hasKeyframe(at: time) {
            let held = value(at: time)
            removeKeyframe(at: time)
            if !isAnimated { value = held }
        } else {
            setKeyframe(Keyframe(time: time, value: value(at: time)))
        }
    }
}
