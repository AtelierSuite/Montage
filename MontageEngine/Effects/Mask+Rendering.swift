import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import os

extension Mask {
    /// The mask over `frame` as the parameters are at `time`: white where
    /// the effect applies, black where it doesn't, and grey along a soft
    /// edge. Opaque across the frame, ready for `CIBlendWithMask`.
    func image(in frame: CGRect, at time: CMTime) -> CIImage {
        let center = center.value(at: time)
        let size = size.value(at: time)
        let width = max(0, size.width * frame.width)
        let height = max(0, size.height * frame.height)
        let featherWidth = max(0, feather.value(at: time) * frame.width)
        // Clockwise on screen, which is the other way in Core Image's
        // coordinates, where y runs up.
        let angle = -rotation.value(at: time) * .pi / 180
        // Where the box's centre is, in Core Image's coordinates.
        let placement = CGAffineTransform(
            translationX: frame.minX + center.x * frame.width, y: frame.maxY - center.y * frame.height
        ).rotated(by: angle)

        let black = CIImage(color: .black).cropped(to: frame)
        var mask: CIImage
        switch shape {
        case .rectangle:
            // Drawn at its full size before it's turned, so its edges are
            // resampled a pixel wide rather than stretched from a smaller one.
            let box = CIImage(color: .white).cropped(to: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            mask = box.transformed(by: placement).composited(over: black)
        case .ellipse:
            mask = Self.ellipse(width: width, height: height, featherWidth: featherWidth)
                .transformed(by: placement).composited(over: black)
        case .path:
            // The box's own coordinates, (0, 0) at its top-left and (1, 1)
            // at its bottom-right, onto the frame's pixels from its corner.
            let transform = CGAffineTransform(scaleX: width, y: -height)
                .concatenating(CGAffineTransform(translationX: -width / 2, y: height / 2))
                .concatenating(placement)
                .concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
            mask = Self.rendering(path.value(at: time).cgPath(transform: transform), size: frame.size)
                .map { $0.transformed(by: CGAffineTransform(translationX: frame.minX, y: frame.minY)).composited(over: black) }
                ?? black
        }
        // The ellipse's gradient is its soft edge already; the others are
        // softened by blurring their sharp one.
        if shape != .ellipse && featherWidth > 0 {
            mask = mask.clampedToExtent().applyingGaussianBlur(sigma: featherWidth / 2)
        }
        mask = mask.cropped(to: frame)
        return isInverted ? mask.applyingFilter("CIColorInvert") : mask
    }

    /// A white ellipse centred on the origin, fading to black over
    /// `featherWidth` across its edge. The gradient is drawn as a circle as
    /// wide as the ellipse's longer side, and only ever squeezed to shape, so
    /// it's never stretched blurry.
    private static func ellipse(width: Double, height: Double, featherWidth: Double) -> CIImage {
        // Squeezed flat, the gradient would be an empty image rather than
        // a black one, and an inverted mask would hide the effect.
        guard width > 0, height > 0 else { return CIImage(color: .black) }
        let radius = max(width, height) / 2
        // The soft edge is measured across the shorter side, where the
        // squeeze leaves it at the width asked for.
        let shorter = max(min(width, height) / 2, 1)
        let band = featherWidth / shorter * radius
        let filter = CIFilter.radialGradient()
        filter.center = .zero
        filter.radius0 = Float(max(0, radius - band / 2))
        // A pixel's fade even when sharp, so the edge is smooth.
        filter.radius1 = Float(max(radius + band / 2, Double(filter.radius0) + 1))
        filter.color0 = .white
        filter.color1 = .black
        let circle = filter.outputImage ?? CIImage(color: .black)
        return circle.transformed(by: CGAffineTransform(scaleX: width / 2 / radius, y: height / 2 / radius))
    }

    /// A path filled white on black, drawn into a frame-sized bitmap.
    /// The last one drawn is kept, since a path that isn't keyframed is the
    /// same frame after frame.
    private static func rendering(_ path: CGPath, size: CGSize) -> CIImage? {
        let pixelWidth = Int(size.width.rounded(.up))
        let pixelHeight = Int(size.height.rounded(.up))
        guard pixelWidth > 0, pixelHeight > 0, !path.isEmpty else { return nil }
        let key = PathRendering.Key(path: path, width: pixelWidth, height: pixelHeight)
        if let image = PathRendering.last.withLock({ $0?.key == key ? $0?.image : nil }) {
            return image
        }
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.setFillColor(gray: 1, alpha: 1)
        context.addPath(path)
        context.fillPath()
        guard let cgImage = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cgImage)
        PathRendering.last.withLock { $0 = PathRendering(key: key, image: image) }
        return image
    }
}

/// The path mask drawn last, and what it was drawn from.
private struct PathRendering: @unchecked Sendable {
    // The path is never changed once it's made.
    struct Key: Equatable, @unchecked Sendable {
        var path: CGPath
        var width: Int
        var height: Int
    }

    var key: Key
    // CIImage is immutable, so it's safe to hand between threads.
    var image: CIImage

    static let last = OSAllocatedUnfairLock<PathRendering?>(initialState: nil)
}
