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

    /// Whether an effect is the Basic Title, whatever language Final Cut
    /// named it in.
    static func isBasicTitle(_ effect: MarkupElement?) -> Bool {
        guard let uid = effect?["uid"] else { return false }
        return uid.hasSuffix("/Basic Title.moti")
    }

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

    // MARK: - Reading

    /// What a title's words and formatting come to in Montage.
    struct Reading {
        var text: TextContent
        /// What didn't come across, by the setting's name.
        var unsupported: [String] = []
    }

    /// A title's words, and their formatting where Montage has it. The
    /// first piece's formatting is the clip's style; the weight, slant and
    /// colour of the others are their own. `definitions` are the
    /// document's text style definitions by ID.
    static func read(_ title: MarkupElement, definitions: [String: MarkupElement]) -> Reading {
        var pieces: [(text: String, attributes: [String: String], isAnimated: Bool)] = []
        for (index, text) in title.children("text").enumerated() {
            // Each text element is a block of its own, on its own line.
            if index > 0, !pieces.isEmpty { pieces[pieces.count - 1].text += "\n" }
            for style in text.children("text-style") {
                let definition = style["ref"].flatMap { definitions[$0] }?.child("text-style")
                var attributes: [String: String] = [:]
                for attribute in definition?.attributes ?? [] { attributes[attribute.name] = attribute.value }
                for attribute in style.attributes where attribute.name != "ref" { attributes[attribute.name] = attribute.value }
                let isAnimated = !(definition?.children("param").isEmpty ?? true) || !style.children("param").isEmpty
                pieces.append((style.text, attributes, isAnimated))
            }
            // Words written straight into the text, with no style of their own.
            if text.children.isEmpty, !text.text.isEmpty { pieces.append((text.text, [:], false)) }
        }

        var unsupported: [String] = []
        func note(_ name: String) { if !unsupported.contains(name) { unsupported.append(name) } }

        let base = pieces.first?.attributes ?? [:]
        let style = Self.style(from: base)
        var runs: [TextRun] = []
        for piece in pieces {
            let attributes = piece.attributes
            if piece.isAnimated { note("Text style animation") }
            for name in ["baseline", "baselineOffset", "tabStops", "underline", "backgroundColor"] where attributes[name] != nil {
                if name == "underline", attributes[name] == "0" { continue }
                note(settingName(name))
            }
            // What can differ from piece to piece in Montage.
            let own = Self.style(from: attributes)
            var formatting = TextRun.Formatting()
            if own.weight != style.weight { formatting.weight = own.weight }
            if own.isItalic != style.isItalic { formatting.isItalic = own.isItalic }
            let color = own.fill.color.value
            if color != style.fill.color.value { formatting.color = color }
            // What can't.
            for name in ["font", "fontSize", "strokeColor", "strokeWidth", "shadowColor", "shadowOffset",
                         "shadowBlurRadius", "kerning", "lineSpacing", "alignment"] where attributes[name] != base[name] {
                note("Text style per word")
                break
            }
            runs.append(TextRun(piece.text, formatting: formatting))
        }
        return Reading(text: TextContent(runs: runs, style: style), unsupported: unsupported)
    }

    /// A text style's attributes as Montage's style for a whole clip.
    static func style(from attributes: [String: String]) -> TextStyle {
        var style = TextStyle(fontFamily: attributes["font"] ?? "Helvetica", fontSize: 63, weight: .regular)
        if let size = attributes["fontSize"].flatMap(Double.init), size > 0 { style.fontSize = Animatable(size) }
        let face = fontFace(attributes["fontFace"] ?? "Regular")
        style.weight = attributes["bold"] == "1" ? max(face.weight, .bold) : face.weight
        style.isItalic = attributes["italic"] == "1" || face.isItalic
        // With no colour of its own, the Basic Title's words are white.
        style.fill = LayerFill(style: .solid, color: attributes["fontColor"].flatMap(color) ?? .white)
        if let color = attributes["strokeColor"].flatMap(color) {
            let width = attributes["strokeWidth"].flatMap(Double.init) ?? 1
            // A negative width, as in Cocoa, also strokes.
            style.outline = LayerStroke(isEnabled: width != 0, color: color, width: abs(width))
        }
        if let color = attributes["shadowColor"].flatMap(color) {
            let parts = (attributes["shadowOffset"] ?? "").split(separator: " ").compactMap { Double($0) }
            let distance = parts.first ?? 0
            let angle = (parts.count > 1 ? parts[1] : 0) * .pi / 180
            style.shadow = LayerShadow(
                isEnabled: true, color: color, blur: attributes["shadowBlurRadius"].flatMap(Double.init) ?? 0,
                offset: CGSize(width: distance * cos(angle), height: -distance * sin(angle))
            )
        }
        if let kerning = attributes["kerning"].flatMap(Double.init) { style.letterSpacing = Animatable(kerning) }
        if let spacing = attributes["lineSpacing"].flatMap(Double.init) { style.lineSpacing = Animatable(spacing) }
        switch attributes["alignment"] {
        case "left", "justified": style.alignment = .leading
        case "right": style.alignment = .trailing
        default: style.alignment = .center
        }
        return style
    }

    /// A face's name, such as "Condensed Bold Italic", as its weight and
    /// slant.
    static func fontFace(_ name: String) -> (weight: FontWeight, isItalic: Bool) {
        let face = name.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "-", with: "")
        let isItalic = face.contains("italic") || face.contains("oblique")
        let weights: [(String, FontWeight)] = [
            ("ultralight", .ultraLight), ("extralight", .ultraLight), ("hairline", .thin), ("thin", .thin),
            ("semibold", .semibold), ("demibold", .semibold), ("extrabold", .heavy), ("ultrabold", .heavy),
            ("heavy", .heavy), ("black", .black), ("bold", .bold), ("medium", .medium), ("light", .light),
        ]
        let weight = weights.first { face.contains($0.0) }?.1 ?? .regular
        return (weight, isItalic)
    }

    /// "1 0.5 0 1" as a colour; a missing alpha is opaque.
    static func color(_ string: String) -> RGBAColor? {
        let parts = string.split(separator: " ").compactMap { Double($0) }
        guard parts.count >= 3 else { return nil }
        return RGBAColor(red: parts[0], green: parts[1], blue: parts[2], alpha: parts.count > 3 ? parts[3] : 1)
    }

    /// "tabStops" as "Tab stops".
    private static func settingName(_ attribute: String) -> String {
        switch attribute {
        case "backgroundColor": return "Text background"
        case "baselineOffset": return "Baseline offset"
        case "tabStops": return "Tab stops"
        default: return attribute.prefix(1).uppercased() + attribute.dropFirst()
        }
    }
}
