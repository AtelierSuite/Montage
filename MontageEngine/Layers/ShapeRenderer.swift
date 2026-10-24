import CoreGraphics
import Foundation

/// Draws a shape into a picture of its own, just big enough for it, its
/// stroke and its shadow, for the compositor to place like any other layer.
public enum ShapeRenderer {
    /// The shape drawn at `scale` pixels to each of the frame's pixels. Nil
    /// when there's nothing to draw.
    static func image(of shape: ShapeContent.Resolved, scale: Double) -> DrawnLayer? {
        let isLine = shape.kind == .line
        // A line with no stroke is drawn in its fill's colour, as thick as
        // its box is tall.
        let stroke = shape.stroke ?? (isLine && shape.fill.style != .none ? LayerStroke.Resolved(
            color: shape.fill.color, width: max(shape.height, 1), dash: .solid, cap: .butt, join: .miter
        ) : nil)
        let height = isLine ? 0 : shape.height
        guard shape.width > 0, height > 0 || isLine, stroke != nil || shape.fill.style != .none else { return nil }

        let width = stroke?.width ?? 0
        let pointed = [.star, .arrow, .polygon].contains(shape.kind) && stroke?.join == .miter
        let margin = ceil(width * (pointed ? 2.5 : 1) + (shape.shadow?.reach ?? 0) + 2)
        let size = CGSize(width: shape.width + margin * 2, height: height + margin * 2)
        guard let canvas = LayerCanvas(size: size, scale: scale) else { return nil }
        let context = canvas.context
        // Shapes are laid out with y running down, as the frame's is.
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let box = CGRect(x: margin, y: margin, width: shape.width, height: height)
        let path = path(of: shape, in: box)

        canvas.beginShadow(shape.shadow)
        if !isLine {
            switch shape.fill.style {
            case .none:
                break
            case .solid:
                context.addPath(path)
                context.setFillColor(shape.fill.color.cgColor)
                context.fillPath()
            case .linearGradient, .radialGradient:
                context.saveGState()
                context.addPath(path)
                context.clip()
                LayerCanvas.drawGradient(shape.fill, in: box, context: context, yRunsDown: true)
                context.restoreGState()
            }
        }
        if let stroke {
            context.addPath(path)
            context.setStrokeColor(stroke.color.cgColor)
            context.setLineWidth(stroke.width)
            let join: CGLineJoin = switch stroke.join {
            case .miter: .miter
            case .round: .round
            case .bevel: .bevel
            }
            context.setLineJoin(join)
            var cap: CGLineCap = switch stroke.cap {
            case .butt: .butt
            case .round: .round
            case .square: .square
            }
            switch stroke.dash {
            case .solid:
                break
            case .dashed:
                context.setLineDash(phase: 0, lengths: [stroke.width * 3, stroke.width * 2])
            case .dotted:
                // Dots need round ends to be dots.
                cap = .round
                context.setLineDash(phase: 0, lengths: [0, stroke.width * 2])
            }
            context.setLineCap(cap)
            context.strokePath()
        }
        canvas.endShadow(shape.shadow)
        return context.makeImage().map { DrawnLayer(image: $0, scale: canvas.scale) }
    }

    /// The shape's outline in a box, with y running down.
    public static func path(of shape: ShapeContent.Resolved, in box: CGRect) -> CGPath {
        switch shape.kind {
        case .rectangle:
            return CGPath(rect: box, transform: nil)
        case .roundedRectangle:
            let radius = min(shape.cornerRadius, box.width / 2, box.height / 2)
            return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        case .ellipse:
            return CGPath(ellipseIn: box, transform: nil)
        case .line:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: box.minX, y: box.midY))
            path.addLine(to: CGPoint(x: box.maxX, y: box.midY))
            return path
        case .arrow:
            let shaft = box.height * 0.4
            let head = min(box.width * 0.45, box.height * 0.9)
            let neck = box.maxX - head
            let path = CGMutablePath()
            path.addLines(between: [
                CGPoint(x: box.minX, y: box.midY - shaft / 2), CGPoint(x: neck, y: box.midY - shaft / 2),
                CGPoint(x: neck, y: box.minY), CGPoint(x: box.maxX, y: box.midY), CGPoint(x: neck, y: box.maxY),
                CGPoint(x: neck, y: box.midY + shaft / 2), CGPoint(x: box.minX, y: box.midY + shaft / 2),
            ])
            path.closeSubpath()
            return path
        case .polygon, .star:
            let isStar = shape.kind == .star
            let corners = shape.sides * (isStar ? 2 : 1)
            let points = (0..<corners).map { index -> CGPoint in
                // From the top, clockwise.
                let angle = -Double.pi / 2 + Double(index) * 2 * .pi / Double(corners)
                let radius = isStar && index % 2 == 1 ? shape.innerRadius : 1
                return CGPoint(x: box.midX + cos(angle) * box.width / 2 * radius,
                               y: box.midY + sin(angle) * box.height / 2 * radius)
            }
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            return path
        }
    }
}

/// A text or shape layer's picture, and the scale it was drawn at: how many
/// of its pixels make one of the frame's.
struct DrawnLayer: @unchecked Sendable {
    let image: CGImage
    let scale: Double
}
