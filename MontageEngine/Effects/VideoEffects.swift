import CoreImage
import CoreMedia

/// What a video effect needs to know to change one frame.
public struct VideoEffectContext: Sendable {
    /// The size of the frame being rendered.
    public var renderSize: CGSize
    /// The frame's time from its clip's start, the time keyframes are
    /// evaluated at.
    public var clipTime: CMTime

    public init(renderSize: CGSize, clipTime: CMTime) {
        self.renderSize = renderSize
        self.clipTime = clipTime
    }
}

extension Effect {
    /// The image with this effect applied, at the context's time. An effect
    /// that's turned off, or changes only the sound, leaves it as it is.
    public func apply(to image: CIImage, in context: VideoEffectContext) -> CIImage {
        guard isEnabled, kind.isVideo else { return image }
        return VideoEffects.apply(kind, to: image, in: context)
    }
}

extension Array where Element == Effect {
    /// The image with each of the effects applied in turn.
    public func apply(to image: CIImage, in context: VideoEffectContext) -> CIImage {
        reduce(image) { image, effect in effect.apply(to: image, in: context) }
    }
}

/// Where each kind of video effect changes the picture, called by the
/// compositor for every frame.
enum VideoEffects {
    static func apply(_ kind: Effect.Kind, to image: CIImage, in context: VideoEffectContext) -> CIImage {
        image
    }
}
