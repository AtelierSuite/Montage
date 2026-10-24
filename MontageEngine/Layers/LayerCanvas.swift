import CoreGraphics
import Foundation

/// A bitmap to draw a text or shape layer into, measured in the frame's
/// pixels and drawn at `scale` times that, so the layer stays sharp however
/// big it's shown. y runs up from the bottom-left, as Core Graphics' does.
struct LayerCanvas {
    /// The most pixels a side can have; a bigger layer is drawn at a smaller
    /// scale.
    static let maximumSide = 8192.0

    let context: CGContext
    let scale: Double

    init?(size: CGSize, scale: Double) {
        guard size.width > 0, size.height > 0, scale > 0 else { return nil }
        let scale = min(scale, Self.maximumSide / max(size.width, size.height))
        let width = Int(ceil(size.width * scale))
        let height = Int(ceil(size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        self.context = context
        self.scale = scale
    }

    /// Starts drawing what casts a shadow, as one layer so its parts cast
    /// one shadow together. The shadow's offset has y running down.
    func beginShadow(_ shadow: LayerShadow.Resolved?) {
        guard let shadow else { return }
        // Shadows are measured in the bitmap's own pixels, with y running up.
        context.setShadow(
            offset: CGSize(width: shadow.offsetX * scale, height: -shadow.offsetY * scale),
            blur: shadow.blur * scale, color: shadow.color.cgColor
        )
        context.beginTransparencyLayer(auxiliaryInfo: nil)
    }

    func endShadow(_ shadow: LayerShadow.Resolved?) {
        guard shadow != nil else { return }
        context.endTransparencyLayer()
    }

    /// A grey mask the size of a canvas: white where `draw` paints.
    static func mask(size: CGSize, scale: Double, draw: (CGContext) -> Void) -> CGImage? {
        let scale = min(scale, maximumSide / max(size.width, size.height))
        guard let context = CGContext(
            data: nil, width: Int(ceil(size.width * scale)), height: Int(ceil(size.height * scale)), bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.scaleBy(x: scale, y: scale)
        draw(context)
        return context.makeImage()
    }

    /// Paints a fill's gradient across a rectangle. Angles turn clockwise
    /// on screen, whichever way the context's y runs.
    static func drawGradient(_ fill: LayerFill.Resolved, in rect: CGRect, context: CGContext, yRunsDown: Bool) {
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [fill.color.cgColor, fill.endColor.cgColor] as CFArray,
            locations: [0, 1]
        ) else { return }
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        switch fill.style {
        case .radialGradient:
            let radius = hypot(rect.width, rect.height) / 2
            context.drawRadialGradient(
                gradient, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius,
                options: [.drawsAfterEndLocation]
            )
        default:
            let angle = fill.angle * .pi / 180
            let direction = CGPoint(x: cos(angle), y: yRunsDown ? sin(angle) : -sin(angle))
            // Far enough each way to reach the rectangle's corners.
            let reach = abs(rect.width / 2 * direction.x) + abs(rect.height / 2 * direction.y)
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: centre.x - direction.x * reach, y: centre.y - direction.y * reach),
                end: CGPoint(x: centre.x + direction.x * reach, y: centre.y + direction.y * reach),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
            )
        }
    }
}

extension RGBAColor {
    var cgColor: CGColor {
        CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}
