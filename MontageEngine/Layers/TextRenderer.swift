import CoreGraphics
import CoreText
import Foundation

/// Lays text out with Core Text and draws it into a picture of its own,
/// just big enough for the words, their outline and shadow and the box
/// behind them, for the compositor to place like any other layer.
enum TextRenderer {
    /// The text drawn at `scale` pixels to each of the frame's pixels. Nil
    /// when there's nothing to draw.
    static func image(of text: TextContent.Resolved, scale: Double) -> DrawnLayer? {
        let string = text.runs.map(\.text).joined()
        guard !string.isEmpty else { return nil }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString(text))
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: text.wrapWidth, height: .greatestFiniteMagnitude), nil
        )
        let textSize = CGSize(width: ceil(suggested.width) + 1, height: ceil(suggested.height) + 1)
        let margin = ceil((text.background?.padding ?? 0) + (text.outline?.width ?? 0) + (text.shadow?.reach ?? 0) + 2)
        let size = CGSize(width: textSize.width + margin * 2, height: textSize.height + margin * 2)
        guard let canvas = LayerCanvas(size: size, scale: scale) else { return nil }
        let context = canvas.context
        // Core Text draws with y running up, as the context does.
        let textRect = CGRect(x: margin, y: margin, width: textSize.width, height: textSize.height)
        let path = CGPath(rect: textRect, transform: nil)
        func draw(_ attributed: CFAttributedString, in context: CGContext) {
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(), path, nil), context)
        }

        canvas.beginShadow(text.shadow)
        if let background = text.background {
            let box = textRect.insetBy(dx: -background.padding, dy: -background.padding)
            let radius = min(background.cornerRadius, box.width / 2, box.height / 2)
            context.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(background.color.cgColor)
            context.fillPath()
        }
        if let outline = text.outline {
            // Twice as wide, under the fill, so the outline's width shows
            // outside the letters.
            draw(attributedString(text, outline: outline), in: context)
        }
        switch text.fill.style {
        case .none:
            break
        case .solid:
            draw(attributedString(text), in: context)
        case .linearGradient, .radialGradient:
            // The letters as a mask, with the gradient painted through it.
            if let mask = LayerCanvas.mask(size: size, scale: canvas.scale, draw: { draw(attributedString(text, color: .white), in: $0) }) {
                context.saveGState()
                context.clip(to: CGRect(origin: .zero, size: size), mask: mask)
                LayerCanvas.drawGradient(text.fill, in: textRect, context: context, yRunsDown: false)
                context.restoreGState()
            }
        }
        canvas.endShadow(text.shadow)
        return context.makeImage().map { DrawnLayer(image: $0, scale: canvas.scale) }
    }

    /// The words with their fonts, spacing and colours: in their own colours,
    /// in one colour, or as an outline.
    static func attributedString(
        _ text: TextContent.Resolved, color: RGBAColor? = nil, outline: LayerStroke.Resolved? = nil
    ) -> CFAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = paragraphStyle(text)
        for run in text.runs {
            let font = FontResolver.font(
                family: text.fontFamily, size: text.fontSize, weight: run.formatting.weight ?? text.weight,
                isItalic: run.formatting.isItalic ?? text.isItalic
            )
            let fill = color ?? run.formatting.color ?? text.fill.color
            var attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTKernAttributeName as String): text.letterSpacing,
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill.cgColor,
            ]
            if let outline {
                // A positive width strokes without filling, as a percentage
                // of the font's size.
                attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = outline.width * 2 / text.fontSize * 100
                attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = outline.color.cgColor
            }
            result.append(NSAttributedString(string: run.text, attributes: attributes))
        }
        return result
    }

    private static func paragraphStyle(_ text: TextContent.Resolved) -> CTParagraphStyle {
        var alignment: CTTextAlignment = switch text.alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
        var spacing = CGFloat(text.lineSpacing)
        return withUnsafeBytes(of: &alignment) { alignment in
            withUnsafeBytes(of: &spacing) { spacing in
                let settings = [
                    CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: alignment.baseAddress!),
                    CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: spacing.baseAddress!),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }
}
