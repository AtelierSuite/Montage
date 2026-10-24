import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine

/// Text clips as Final Cut titles, and back.
///
/// A title is an instance of a Motion template, the `effect` it refers to,
/// with its words in `text` elements. Each stretch of words formatted alike
/// is a `text-style` naming a `text-style-def` by ID, which holds the
/// formatting. IDs are the whole document's, so a title can use a style
/// another title defined.
///
/// Montage's text goes out as the Basic Title, which Final Cut has built in:
/// it draws the words in the frame's centre with nothing else, as Montage
/// does.
enum FCPXMLTitles {
    static let basicTitleName = "Basic Title"
    static let basicTitleUID = ".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"

    // MARK: - Writing

    /// A text clip's words, as a `text` element, and the style definitions
    /// its pieces name, one for each formatting they use. `nextID` gives a
    /// new style ID.
    static func textElements(for text: TextContent, nextID: () -> String) -> (text: MarkupElement, definitions: [MarkupElement]) {
        var ids: [TextRun.Formatting: String] = [:]
        var definitions: [MarkupElement] = []
        var pieces: [MarkupElement] = []
        for run in text.runs {
            let id: String
            if let existing = ids[run.formatting] {
                id = existing
            } else {
                id = nextID()
                ids[run.formatting] = id
                definitions.append(MarkupElement("text-style-def", [("id", id)], children: [
                    MarkupElement("text-style", attributes(of: text.style, formatting: run.formatting)),
                ]))
            }
            pieces.append(MarkupElement("text-style", [("ref", id)], text: run.text))
        }
        return (MarkupElement("text", children: pieces), definitions)
    }

    /// A piece's formatting as Final Cut's text style attributes: its own
    /// weight, slant and colour over the clip's style. Values are the
    /// clip's at its start.
    static func attributes(of style: TextStyle, formatting: TextRun.Formatting) -> [(String, String?)] {
        let weight = formatting.weight ?? style.weight
        let isItalic = formatting.isItalic ?? style.isItalic
        let fill = style.fill.style == .none ? RGBAColor.clear : formatting.color ?? style.fill.color.value(at: .zero)
        var attributes: [(String, String?)] = [
            ("font", style.fontFamily), ("fontSize", decimal(style.fontSize.value(at: .zero))),
            ("fontFace", fontFace(weight: weight, isItalic: isItalic)), ("fontColor", color(fill)),
            ("bold", weight >= .bold ? "1" : nil), ("italic", isItalic ? "1" : nil),
        ]
        if let outline = style.outline.resolved(at: .zero) {
            attributes += [("strokeColor", color(outline.color)), ("strokeWidth", decimal(outline.width))]
        }
        if let shadow = style.shadow.resolved(at: .zero) {
            let distance = hypot(shadow.offsetX, shadow.offsetY)
            // Final Cut's angle turns anticlockwise from pointing right, with
            // y running up; Montage's offset runs down.
            var angle = atan2(-shadow.offsetY, shadow.offsetX) * 180 / .pi
            if angle < 0 { angle += 360 }
            attributes += [
                ("shadowColor", color(shadow.color)), ("shadowOffset", "\(decimal(distance)) \(decimal(distance == 0 ? 0 : angle))"),
                ("shadowBlurRadius", decimal(shadow.blur)),
            ]
        }
        let spacing = style.letterSpacing.value(at: .zero)
        let lineSpacing = style.lineSpacing.value(at: .zero)
        attributes += [
            ("kerning", spacing == 0 ? nil : decimal(spacing)),
            ("alignment", alignment(style.alignment)),
            ("lineSpacing", lineSpacing == 0 ? nil : decimal(lineSpacing)),
        ]
        return attributes
    }

    /// The name of a font's face, as Final Cut gives it: "Bold Italic".
    static func fontFace(weight: FontWeight, isItalic: Bool) -> String {
        let name = switch weight {
        case .ultraLight: "UltraLight"
        case .thin: "Thin"
        case .light: "Light"
        case .regular: "Regular"
        case .medium: "Medium"
        case .semibold: "Semibold"
        case .bold: "Bold"
        case .heavy: "Heavy"
        case .black: "Black"
        }
        guard isItalic else { return name }
        return weight == .regular ? "Italic" : name + " Italic"
    }

    private static func alignment(_ alignment: TextAlignment) -> String {
        switch alignment {
        case .leading: "left"
        case .center: "center"
        case .trailing: "right"
        }
    }

    private static func color(_ color: RGBAColor) -> String {
        [color.red, color.green, color.blue, color.alpha].map(decimal).joined(separator: " ")
    }

    private static func decimal(_ value: Double) -> String { FCPXMLExporter.decimal(value) }
}
