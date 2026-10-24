import CoreGraphics
import CoreMedia

extension Clip {
    /// Whether the clip slowly pans and zooms across its picture: its scale
    /// and position each keyframed from its start to its end.
    public var hasKenBurns: Bool {
        transform.scale.isAnimated && transform.position.isAnimated
    }

    /// Slowly zooms in on the picture across the whole clip, drifting from
    /// one side towards the middle, with keyframes at its start and end that
    /// can be changed like any others.
    public mutating func applyKenBurns(zoom: Double = 1.15, drift: CGPoint = CGPoint(x: 0.03, y: 0.02)) {
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

    /// Stops the pan and zoom, leaving the picture as it is at the start.
    public mutating func removeKenBurns() {
        transform.scale = Animatable(transform.scale.keyframes.first?.value ?? transform.scale.value)
        let start = transform.position.keyframes.last?.value ?? transform.position.value
        transform.position = Animatable(start)
    }
}
