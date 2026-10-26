import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine

/// What a Resolve clip's Inspector settings come to in Montage.
///
/// They're in the clip's `EffectFiltersBA` (see `ResolveBlobs.filters`), a
/// filter for each Inspector group. What each filter and parameter is was
/// worked out from Blackmagic's training projects, against the values their
/// books give (see issue #61):
///
/// - Transform (filter 4): Zoom X and Y (42, 43), 1 fitting the frame, and
///   Position X and Y (40, 41) as fractions of the timeline's width and
///   height, from its centre, up being positive.
/// - Composite (2): the composite mode (0) and the opacity in percent (1).
/// - Cropping (6), Retime and Scaling (44), Dynamic Zoom (118).
/// - The fade handles of a picture (72: 137 in, 138 out) and of a sound
///   (124: 97 in, 98 out), in frames.
/// - Volume (124: 95), in decibels.
/// - Open FX effects (50), naming their plugin.
///
/// Anything else that's set is reported rather than guessed at.
enum ResolveClipSettings {
    /// Something that didn't come across as it was.
    enum Note: Equatable {
        case setting(String)
        case uneven(String)
        /// An effect, kept on the clip turned off.
        case effect(identifier: String, name: String)
    }

    private enum Filter {
        static let composite = 2
        static let transform = 4
        static let cropping = 6
        static let retimeAndScaling = 44
        static let openFX = 50
        static let videoFades = 72
        static let dynamicZoom = 118
        static let audio = 124
    }

    /// Applies the filters to the clip, timing keyframes from `inPoint`,
    /// the frame of the source the clip starts at, as the clip's `In` is.
    static func apply(
        _ filters: [ResolveBlobs.Filter], to clip: inout Clip, isVideo: Bool, inPoint: Int64, frameDuration: CMTime
    ) -> [Note] {
        var notes: [Note] = []
        func time(_ frame: Int64) -> CMTime {
            InterchangeTime.frames(frame - inPoint, frameDuration: frameDuration) ?? .zero
        }
        func animatable(_ parameter: ResolveBlobs.Parameter?, default value: Double) -> Animatable<Double>? {
            guard let parameter, parameter.number != nil || !parameter.keyframes.isEmpty else { return nil }
            let keyframes = parameter.keyframes.map { Keyframe(time: time($0.frame), value: $0.value) }
            return Animatable(parameter.number ?? keyframes.first?.value ?? value, keyframes: keyframes)
        }
        let clipDuration = clip.duration
        /// The value faded in and out over the clip's first and last frames.
        func faded(
            _ value: Animatable<Double>, in fadeIn: ResolveBlobs.Parameter?, out fadeOut: ResolveBlobs.Parameter?
        ) -> Animatable<Double> {
            let lengths = (fadeIn?.number ?? 0, fadeOut?.number ?? 0)
            guard lengths.0 > 0 || lengths.1 > 0 else { return value }
            guard !value.isAnimated else {
                notes.append(.setting("Fade"))
                return value
            }
            // A length in frames, which may have a part of a frame.
            func length(_ frames: Double) -> CMTime {
                guard frames > 0 else { return .zero }
                let whole = frames.rounded()
                let time = whole == frames && whole < 1e9
                    ? InterchangeTime.frames(Int64(whole), frameDuration: frameDuration) ?? .zero
                    : CMTimeMultiplyByFloat64(frameDuration, multiplier: frames)
                return min(time, clipDuration)
            }
            let fadeIn = length(lengths.0)
            let fadeOut = min(length(lengths.1), clipDuration - fadeIn)
            var keyframes: [Keyframe<Double>] = []
            if fadeIn > .zero { keyframes += [Keyframe(time: .zero, value: 0), Keyframe(time: fadeIn, value: value.value)] }
            if fadeOut > .zero {
                keyframes += [Keyframe(time: clipDuration - fadeOut, value: value.value), Keyframe(time: clipDuration, value: 0)]
            }
            return Animatable(value.value, keyframes: keyframes)
        }

        for filter in filters where !filter.parameters.isEmpty || filter.plugin != nil {
            var parameters = filter.parameters
            switch filter.type {
            case Filter.transform where isVideo:
                let zoomX = animatable(parameters.removeValue(forKey: 42), default: 1)
                let zoomY = animatable(parameters.removeValue(forKey: 43), default: 1)
                if let zoom = zoomX ?? zoomY {
                    clip.transform.scale = zoom
                    if (zoomX ?? Animatable(1)) != (zoomY ?? Animatable(1)) { notes.append(.uneven("Zoom")) }
                }
                let x = animatable(parameters.removeValue(forKey: 40), default: 0)
                let y = animatable(parameters.removeValue(forKey: 41), default: 0)
                if x != nil || y != nil {
                    clip.transform.position = position(x: x ?? Animatable(0), y: y ?? Animatable(0))
                }
                if !parameters.isEmpty { notes.append(.setting("Rotation, anchor point, pitch, yaw or flip")) }
            case Filter.composite where isVideo:
                if let opacity = animatable(parameters.removeValue(forKey: 1), default: 100) {
                    clip.opacity = opacity.mapped { min(1, max(0, $0 / 100)) }
                }
                if let mode = parameters.removeValue(forKey: 0) {
                    if let blendMode = mode.number.flatMap({ Self.blendModes[Int($0)] }) {
                        clip.blendMode = blendMode
                    } else {
                        notes.append(.setting("Composite mode"))
                    }
                }
                if !parameters.isEmpty { notes.append(.setting("Composite")) }
            case Filter.cropping:
                notes.append(.setting("Crop"))
            case Filter.retimeAndScaling:
                // Scaling set to Fit, as Montage fits every picture.
                if parameters[92]?.number == 2 { parameters[92] = nil }
                if !parameters.isEmpty { notes.append(.setting("Retime and scaling")) }
            case Filter.dynamicZoom:
                notes.append(.setting("Dynamic zoom"))
            case Filter.videoFades where isVideo:
                clip.opacity = faded(clip.opacity, in: parameters.removeValue(forKey: 137), out: parameters.removeValue(forKey: 138))
                if !parameters.isEmpty { notes.append(.setting("Fade")) }
            case Filter.audio:
                if let volume = animatable(parameters.removeValue(forKey: 95), default: 0) {
                    clip.volume = volume.mapped { $0 <= -96 ? 0 : pow(10, $0 / 20) }
                }
                clip.volume = faded(clip.volume, in: parameters.removeValue(forKey: 97), out: parameters.removeValue(forKey: 98))
                // The shapes of the fades.
                if parameters.removeValue(forKey: 99) != nil || parameters.removeValue(forKey: 100) != nil {
                    notes.append(.setting("Fade curve"))
                }
                if !parameters.isEmpty { notes.append(.setting("Audio")) }
            case Filter.openFX:
                let plugin = filter.plugin ?? "EffectFiltersBA"
                notes.append(.effect(identifier: plugin, name: plugin.split(separator: ".").last.map(String.init) ?? plugin))
            default:
                notes.append(.effect(identifier: "EffectFiltersBA", name: "Resolve effects"))
            }
        }
        return notes
    }

    /// Composite modes, by their number: those whose number a training
    /// project and its book together confirm, and Normal.
    static let blendModes: [Int: BlendMode] = [0: .normal, 4: .multiply, 5: .screen, 6: .overlay]

    /// Montage's position, from the frame's top-left corner, from Resolve's
    /// two, from its centre and upwards; keyframed where either is.
    private static func position(x: Animatable<Double>, y: Animatable<Double>) -> Animatable<CGPoint> {
        func point(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: 0.5 + x, y: 0.5 - y) }
        let times = Set(x.keyframes.map(\.time) + y.keyframes.map(\.time)).sorted()
        return Animatable(point(x.value, y.value), keyframes: times.map {
            Keyframe(time: $0, value: point(x.value(at: $0), y.value(at: $0)))
        })
    }
}
