import CoreMedia

/// Visits each of a clip's `Animatable` parameters in turn, to read or change
/// their keyframes whatever their value's type.
public protocol AnimatableVisitor {
    mutating func visit<Value: Interpolatable>(_ parameter: inout Animatable<Value>)
}

/// Retiming keyframes and changing how they travel, one parameter at a time.
extension Animatable {
    /// How the keyframe at a time travels on, or nil if there's none there.
    public func interpolation(at time: CMTime) -> Interpolation? {
        keyframes.first { $0.time == time }?.interpolation
    }

    /// Changes how the keyframe at a time travels on to the next. Does
    /// nothing where there's no keyframe.
    public mutating func setInterpolation(_ interpolation: Interpolation, at time: CMTime) {
        guard var keyframe = keyframes.first(where: { $0.time == time }) else { return }
        keyframe.interpolation = interpolation
        setKeyframe(keyframe)
    }

    /// Moves the keyframe at one time to another, replacing any already
    /// there. Does nothing where there's no keyframe.
    public mutating func moveKeyframe(from time: CMTime, to newTime: CMTime) {
        guard time != newTime, var keyframe = keyframes.first(where: { $0.time == time }) else { return }
        removeKeyframe(at: time)
        keyframe.time = newTime
        setKeyframe(keyframe)
    }
}

/// The keyframes of all a clip's parameters taken together, as the timeline
/// shows them: one marker for each time any parameter has a keyframe.
extension Clip {
    /// Visits the clip's parameters: its volume, opacity and transform, and
    /// those of each of its effects and their masks.
    public mutating func visitParameters(_ visitor: inout some AnimatableVisitor) {
        visitor.visit(&volume)
        visitor.visit(&opacity)
        visitor.visit(&transform.position)
        visitor.visit(&transform.scale)
        visitor.visit(&transform.rotation)
        for index in effects.indices {
            effects[index].visitParameters(&visitor)
        }
    }

    /// Every time, from the clip's start, that any of its parameters has a
    /// keyframe, in order.
    public var keyframeTimes: [CMTime] {
        var collector = TimeCollector()
        var clip = self
        clip.visitParameters(&collector)
        return collector.times.sorted()
    }

    /// The last keyframe time before a time from the clip's start.
    public func keyframeTime(before time: CMTime) -> CMTime? {
        keyframeTimes.last { $0 < time }
    }

    /// The first keyframe time after a time from the clip's start.
    public func keyframeTime(after time: CMTime) -> CMTime? {
        keyframeTimes.first { $0 > time }
    }

    /// Moves every parameter's keyframe at one time to another, kept within
    /// the clip. A parameter with a keyframe at the new time already has it
    /// replaced.
    public mutating func moveKeyframes(from time: CMTime, to newTime: CMTime) {
        var mover = KeyframeMover(from: time, to: min(max(newTime, .zero), duration))
        visitParameters(&mover)
    }

    /// How the keyframes at a time travel on: the way they all share, or nil
    /// when there are none there or they differ.
    public func keyframeInterpolation(at time: CMTime) -> Interpolation? {
        var collector = InterpolationCollector(time: time)
        var clip = self
        clip.visitParameters(&collector)
        let found = Set(collector.interpolations)
        return found.count == 1 ? found.first : nil
    }

    /// Changes how every parameter's keyframe at a time travels on.
    public mutating func setKeyframeInterpolation(_ interpolation: Interpolation, at time: CMTime) {
        var setter = InterpolationSetter(time: time, interpolation: interpolation)
        visitParameters(&setter)
    }

    /// Takes away every parameter's keyframe at a time. A parameter left
    /// with none holds the value it had there.
    public mutating func removeKeyframes(at time: CMTime) {
        var remover = KeyframeRemover(time: time)
        visitParameters(&remover)
    }
}

extension Effect {
    /// Visits the effect's parameters, and its mask's.
    public mutating func visitParameters(_ visitor: inout some AnimatableVisitor) {
        switch kind {
        case .colorCorrection(var correction):
            visitor.visit(&correction.exposure)
            visitor.visit(&correction.brightness)
            visitor.visit(&correction.contrast)
            visitor.visit(&correction.saturation)
            visitor.visit(&correction.temperature)
            visitor.visit(&correction.tint)
            visitor.visit(&correction.lift)
            visitor.visit(&correction.gamma)
            visitor.visit(&correction.gain)
            visitor.visit(&correction.lutIntensity)
            kind = .colorCorrection(correction)
        case .mosaic(var mosaic):
            visitor.visit(&mosaic.scale)
            visitor.visit(&mosaic.strength)
            visitor.visit(&mosaic.firstColor)
            visitor.visit(&mosaic.secondColor)
            kind = .mosaic(mosaic)
        case .gain(var gain):
            visitor.visit(&gain.decibels)
            kind = .gain(gain)
        case .pan(var pan):
            visitor.visit(&pan.position)
            kind = .pan(pan)
        case .equalizer(var equalizer):
            for index in equalizer.bands.indices {
                visitor.visit(&equalizer.bands[index].frequency)
                visitor.visit(&equalizer.bands[index].gain)
                visitor.visit(&equalizer.bands[index].bandwidth)
            }
            kind = .equalizer(equalizer)
        case .delay(var delay):
            visitor.visit(&delay.time)
            visitor.visit(&delay.feedback)
            visitor.visit(&delay.mix)
            kind = .delay(delay)
        case .reverb(var reverb):
            visitor.visit(&reverb.mix)
            kind = .reverb(reverb)
        case .unsupported:
            break
        }
        if var mask {
            mask.visitParameters(&visitor)
            self.mask = mask
        }
    }
}

extension Mask {
    public mutating func visitParameters(_ visitor: inout some AnimatableVisitor) {
        visitor.visit(&center)
        visitor.visit(&size)
        visitor.visit(&rotation)
        visitor.visit(&feather)
        visitor.visit(&path)
    }
}

// MARK: - Visitors

private struct TimeCollector: AnimatableVisitor {
    var times: [CMTime] = []

    mutating func visit<Value: Interpolatable>(_ parameter: inout Animatable<Value>) {
        for time in parameter.keyframes.map(\.time) where !times.contains(time) {
            times.append(time)
        }
    }
}

private struct KeyframeMover: AnimatableVisitor {
    let from: CMTime
    let to: CMTime

    mutating func visit<Value: Interpolatable>(_ parameter: inout Animatable<Value>) {
        parameter.moveKeyframe(from: from, to: to)
    }
}

private struct InterpolationCollector: AnimatableVisitor {
    let time: CMTime
    var interpolations: [Interpolation] = []

    mutating func visit<Value: Interpolatable>(_ parameter: inout Animatable<Value>) {
        if let interpolation = parameter.interpolation(at: time) { interpolations.append(interpolation) }
    }
}

private struct InterpolationSetter: AnimatableVisitor {
    let time: CMTime
    let interpolation: Interpolation

    mutating func visit<Value: Interpolatable>(_ parameter: inout Animatable<Value>) {
        parameter.setInterpolation(interpolation, at: time)
    }
}

private struct KeyframeRemover: AnimatableVisitor {
    let time: CMTime

    mutating func visit<Value: Interpolatable>(_ parameter: inout Animatable<Value>) {
        guard parameter.hasKeyframe(at: time) else { return }
        let held = parameter.value(at: time)
        parameter.removeKeyframe(at: time)
        if !parameter.isAnimated { parameter.value = held }
    }
}

extension Project {
    /// Changes a clip in place, on whichever track holds it.
    public mutating func updateClip(_ id: Clip.ID, _ change: (inout Clip) -> Void) {
        guard let index = tracks.firstIndex(where: { $0.clip(id: id) != nil }) else { return }
        tracks[index].update(id, change)
    }
}
