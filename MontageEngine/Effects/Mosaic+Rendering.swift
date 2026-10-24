import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia

extension Mosaic {
    /// The picture, `frame` being its extent, hidden as the parameters are
    /// at `time`. Squares are measured from the frame's top-left corner, so
    /// they line up with its top and leading edges.
    func apply(to image: CIImage, in frame: CGRect, at time: CMTime) -> CIImage {
        let strength = min(max(strength.value(at: time), 0), 1)
        guard strength > 0 else { return image }
        // At least a pixel, or there's nothing to hide behind.
        let size = max(1, scale.value(at: time) * frame.width)

        let hidden: CIImage
        switch style {
        case .pixelate:
            // Each square takes the colour at its middle; spread out past
            // the edges, the squares there have a colour to take.
            let filter = CIFilter.pixellate()
            filter.inputImage = image.clampedToExtent()
            filter.center = CGPoint(x: frame.minX, y: frame.maxY)
            filter.scale = Float(size)
            hidden = filter.outputImage ?? image
        case .blur:
            // Blurred from the frame spread out past its edges, so they
            // don't fade into the transparency beyond.
            hidden = image.clampedToExtent().applyingGaussianBlur(sigma: size)
        case .checkerboard:
            let filter = CIFilter.checkerboardGenerator()
            filter.center = CGPoint(x: frame.minX, y: frame.maxY)
            filter.width = Float(size)
            filter.color0 = firstColor.value(at: time).ciColor
            filter.color1 = secondColor.value(at: time).ciColor
            filter.sharpness = 1
            hidden = (filter.outputImage ?? CIImage.empty()).composited(over: image)
        }
        let cropped = hidden.cropped(to: frame)
        return strength >= 1 ? cropped : image.dissolved(to: cropped, by: strength)
    }
}

extension RGBAColor {
    /// The colour for Core Image, in sRGB as the model keeps it.
    var ciColor: CIColor {
        CIColor(red: red, green: green, blue: blue, alpha: alpha, colorSpace: ColorCorrection.displayColorSpace)
            ?? CIColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
