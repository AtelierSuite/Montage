import CoreGraphics
import CoreImage
import CoreMedia

/// Puts one frame together from its layers' pictures, as Core Image
/// recipes; nothing is drawn until the compositor renders the result.
///
/// Each layer's picture is turned upright and fitted into the frame, centred
/// and keeping its shape, as AVFoundation's own compositor did; then its
/// clip's effects change it, its clip's transform scales, turns and moves
/// it, and its opacity fades it. The layers are laid over black bottom to
/// top, each mixed with what's under it by its blend mode.
///
/// Transforms are worked out where the model describes them, with y running
/// down from the top-left corner, and turned into Core Image's coordinates,
/// where y runs up from the bottom-left, only to apply them.
enum FrameComposer {
    /// A layer's picture for one frame, and the clip parameters to draw it with.
    struct Layer {
        /// The source frame, as stored, before it's turned upright.
        var image: CIImage
        var layer: CompositorLayer
        /// The clip's parameters as of the latest edit.
        var clip: Clip
        /// For text or a shape, how many of the picture's pixels make one
        /// of the frame's. Such a picture is centred in the frame at its own
        /// size rather than fitted into it.
        var drawnScale: Double?
    }

    /// The frame at a time on the timeline. `renderSize` is the project's frame
    /// size, which clip transforms and effects work in; `outputSize` the size
    /// of the buffer it's drawn into, which may be smaller for a quick preview.
    ///
    /// The two layers of a transition, which come one after the other, are
    /// mixed into one first, and that's laid over the layers under them with
    /// the blend mode of the clip that shows more.
    static func compose(_ layers: [Layer], at time: CMTime, renderSize: CGSize, outputSize: CGSize) -> CIImage {
        let frame = CGRect(origin: .zero, size: outputSize)
        var result = CIImage(color: .black).cropped(to: frame)
        var index = layers.startIndex
        while index < layers.endIndex {
            let layer = layers[index]
            index += 1
            guard let transition = layer.layer.transition else {
                if let picture = fadedPicture(layer, at: time, renderSize: renderSize, outputSize: outputSize) {
                    result = blend(picture, over: result, mode: layer.clip.blendMode).cropped(to: frame)
                }
                continue
            }
            var pair = [layer]
            if index < layers.endIndex, layers[index].layer.transition?.id == transition.id {
                pair.append(layers[index])
                index += 1
            }
            let incoming = pair.first { $0.layer.clip.id == transition.incomingClipID }
            let outgoing = pair.first { $0.layer.clip.id != transition.incomingClipID }
            let progress = transition.progress(at: time)
            let clear = CIImage(color: .clear).cropped(to: frame)
            func picture(_ layer: Layer?) -> CIImage {
                guard let layer, let picture = fadedPicture(layer, at: time, renderSize: renderSize, outputSize: outputSize) else {
                    return clear
                }
                return picture.composited(over: clear)
            }
            let mixed = mix(from: picture(outgoing), to: picture(incoming), kind: transition.kind, progress: progress)
            guard let shown = progress < 0.5 ? outgoing ?? incoming : incoming ?? outgoing else { continue }
            result = blend(mixed, over: result, mode: shown.clip.blendMode).cropped(to: frame)
        }
        return result
    }

    /// A layer's picture faded by its clip's opacity, or nil when it's
    /// clear.
    private static func fadedPicture(_ layer: Layer, at time: CMTime, renderSize: CGSize, outputSize: CGSize) -> CIImage? {
        let clipTime = layer.layer.clip.localTime(time)
        let opacity = min(max(layer.clip.opacity.value(at: clipTime), 0), 1)
        guard opacity > 0 else { return nil }
        var picture = self.picture(layer, at: clipTime, renderSize: renderSize, outputSize: outputSize)
        if opacity < 1 {
            picture = picture.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity),
            ])
        }
        return picture
    }

    /// Two pictures of the same extent, part way through a transition from
    /// one to the other.
    static func mix(from outgoing: CIImage, to incoming: CIImage, kind: ClipTransition.Kind, progress: Double) -> CIImage {
        switch kind {
        case .crossDissolve:
            outgoing.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: incoming, kCIInputTimeKey: progress,
            ])
        }
    }

    /// One layer's picture, where it goes in a frame of `outputSize`, with
    /// its effects applied.
    static func picture(_ layer: Layer, at clipTime: CMTime, renderSize: CGSize, outputSize: CGSize) -> CIImage {
        let base: CGAffineTransform
        let sourceHeight: CGFloat
        if let scale = layer.drawnScale, scale > 0 {
            let size = layer.image.extent.size
            base = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale).concatenating(CGAffineTransform(
                translationX: (renderSize.width - size.width / scale) / 2, y: (renderSize.height - size.height / scale) / 2
            ))
            sourceHeight = size.height
        } else {
            base = fitTransform(
                naturalSize: layer.layer.naturalSize, preferredTransform: layer.layer.preferredTransform,
                renderSize: renderSize, fit: layer.clip.fit
            )
            sourceHeight = layer.layer.naturalSize.height
        }
        var picture = layer.image.transformed(
            by: coreImage(base, fromHeight: sourceHeight, toHeight: renderSize.height),
            highQualityDownsample: true
        )
        // Effects see the picture fitted into the project's frame, before the
        // clip's transform, and are kept to the picture's own bounds.
        let bounds = picture.extent
        let context = VideoEffectContext(renderSize: renderSize, clipTime: clipTime)
        picture = layer.clip.effects.apply(to: picture, in: context).cropped(to: bounds)

        let scaleToOutput = CGAffineTransform(
            scaleX: outputSize.width / renderSize.width, y: outputSize.height / renderSize.height
        )
        let placement = clipTransform(layer.clip.transform, renderSize: renderSize, at: clipTime).concatenating(scaleToOutput)
        return picture.transformed(
            by: coreImage(placement, fromHeight: renderSize.height, toHeight: outputSize.height),
            highQualityDownsample: true
        )
    }

    /// A picture mixed with what's under it.
    static func blend(_ picture: CIImage, over background: CIImage, mode: BlendMode) -> CIImage {
        guard let name = filterName(for: mode) else { return picture.composited(over: background) }
        return picture.applyingFilter(name, parameters: [kCIInputBackgroundImageKey: background])
    }

    /// The Core Image filter for a blend mode; nil for normal, which is a
    /// plain source-over.
    static func filterName(for mode: BlendMode) -> String? {
        switch mode {
        case .normal: nil
        case .multiply: "CIMultiplyBlendMode"
        case .screen: "CIScreenBlendMode"
        case .overlay: "CIOverlayBlendMode"
        case .softLight: "CISoftLightBlendMode"
        case .hardLight: "CIHardLightBlendMode"
        case .darken: "CIDarkenBlendMode"
        case .lighten: "CILightenBlendMode"
        case .colorDodge: "CIColorDodgeBlendMode"
        case .colorBurn: "CIColorBurnBlendMode"
        case .difference: "CIDifferenceBlendMode"
        case .exclusion: "CIExclusionBlendMode"
        case .add: "CIAdditionCompositing"
        case .hue: "CIHueBlendMode"
        case .saturation: "CISaturationBlendMode"
        case .color: "CIColorBlendMode"
        case .luminosity: "CILuminosityBlendMode"
        }
    }

    // MARK: - Transforms

    /// Turns a picture upright by its track's preferred transform, then fits
    /// it into the render size, filling or stretched to it if asked, and
    /// centres it.
    static func fitTransform(
        naturalSize: CGSize, preferredTransform: CGAffineTransform, renderSize: CGSize, fit: FrameFit = .fit
    ) -> CGAffineTransform {
        let upright = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        guard upright.width > 0, upright.height > 0 else { return preferredTransform }
        let across = renderSize.width / upright.width
        let down = renderSize.height / upright.height
        let scale: CGSize = switch fit {
        case .fit: CGSize(width: min(across, down), height: min(across, down))
        case .fill: CGSize(width: max(across, down), height: max(across, down))
        case .stretch: CGSize(width: across, height: down)
        }
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -upright.midX, y: -upright.midY))
            .concatenating(CGAffineTransform(scaleX: scale.width, y: scale.height))
            .concatenating(CGAffineTransform(translationX: renderSize.width / 2, y: renderSize.height / 2))
    }

    /// Moves a fitted picture by its clip's transform at a time from the
    /// clip's start: scaled and turned clockwise about its centre, the
    /// middle of the frame, then moved to the clip's position.
    static func clipTransform(_ transform: ClipTransform, renderSize: CGSize, at clipTime: CMTime) -> CGAffineTransform {
        let scale = transform.scale.value(at: clipTime)
        let position = transform.position.value(at: clipTime)
        return CGAffineTransform(translationX: -renderSize.width / 2, y: -renderSize.height / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            // Positive angles turn clockwise when y runs down.
            .concatenating(CGAffineTransform(rotationAngle: transform.rotation.value(at: clipTime) * .pi / 180))
            .concatenating(CGAffineTransform(translationX: position.x * renderSize.width, y: position.y * renderSize.height))
    }

    /// A transform between two spaces whose y runs down, as one between the
    /// same spaces with y running up, for Core Image.
    static func coreImage(_ transform: CGAffineTransform, fromHeight: CGFloat, toHeight: CGFloat) -> CGAffineTransform {
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: fromHeight)
            .concatenating(transform)
            .concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: toHeight))
    }
}
