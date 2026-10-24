import CoreGraphics
import CoreMedia

/// A clip's slow pan and zoom: made of keyframes on its scale and position,
/// which can be changed like any others, and marked so it can be taken off
/// again, putting back the scale and position the clip had before.
public struct KenBurnsMotion: Equatable, Sendable, Codable {
    /// The clip's scale and position before the pan and zoom was put on.
    public var previousScale: Animatable<Double>
    public var previousPosition: Animatable<CGPoint>
}

extension Clip {
    /// Whether the clip slowly pans and zooms across its picture, put on
    /// with `applyKenBurns`. Keyframes set by hand don't count.
    public var hasKenBurns: Bool {
        kenBurns != nil
    }

    /// Slowly zooms in on the picture across the whole clip, drifting from
    /// one side towards the middle, with keyframes at its start and end that
    /// can be changed like any others.
    public mutating func applyKenBurns(zoom: Double = 1.15, drift: CGPoint = CGPoint(x: 0.03, y: 0.02)) {
        if kenBurns == nil {
            kenBurns = KenBurnsMotion(previousScale: transform.scale, previousPosition: transform.position)
        }
        let end = duration
        let scale = transform.scale.value(at: .zero)
        let position = transform.position.value(at: .zero)
        transform.scale = Animatable(scale, keyframes: [
            Keyframe(time: .zero, value: scale, interpolation: .easeInOut),
            Keyframe(time: end, value: scale * zoom),
        ])
        transform.position = Animatable(position, keyframes: [
            Keyframe(time: .zero, value: CGPoint(x: position.x + drift.x, y: position.y + drift.y), interpolation: .easeInOut),
            Keyframe(time: end, value: position),
        ])
    }

    /// Takes the pan and zoom off, putting back the scale and position, and
    /// any keyframes of theirs, from before it was put on.
    public mutating func removeKenBurns() {
        guard let kenBurns else { return }
        transform.scale = kenBurns.previousScale
        transform.position = kenBurns.previousPosition
        self.kenBurns = nil
    }
}
