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
                    MarkupElement("text-style", attributes(of: text.style, formatting: run.formatting),
                                  children: parameters(of: text.style, formatting: run.formatting)),
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
        // Final Cut draws a background only behind captions' words.
        if let background = style.background.resolved(at: .zero) {
            attributes.append(("backgroundColor", color(background.color)))
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

    /// What the attributes can't say about a piece's formatting, as the
    /// settings of the Motion text style Final Cut makes from them, found by
    /// their keys among the style's own: a gradient fill, and keyframes of
    /// the size, fill, outline and shadow. Values are as the attributes
    /// give them, with angles in radians.
    static func parameters(of style: TextStyle, formatting: TextRun.Formatting) -> [MarkupElement] {
        var parameters: [MarkupElement] = []
        if style.fontSize.isAnimated { parameters.append(param("Size", key: "3", style.fontSize, decimal)) }

        let fill = style.fill
        if fill.isGradient && formatting.color == nil {
            let isRadial = fill.style == .radialGradient
            parameters.append(group("Face", key: "14", [
                MarkupElement("param", [("name", "Fill with"), ("key", "15"), ("value", "1 (Gradient)")]),
                group("Gradient", key: "17", [
                    // The ends of the Basic Title's gradient, by its IDs for them.
                    group("RGB", key: "1", [
                        group("RGB1", key: "999140132", [param("Color", key: "3", fill.color, rgb)]),
                        group("RGB2", key: "999140133", [param("Color", key: "3", fill.endColor, rgb)]),
                    ]),
                    MarkupElement("param", [("name", "Type"), ("key", "3"), ("value", isRadial ? "1 (Radial)" : "0 (Linear)")]),
                    // Anticlockwise with y running up, where Montage's turns clockwise.
                    param("Angle", key: "4", fill.angle) { decimal(-$0 * .pi / 180) },
                ]),
            ]))
        } else if fill.style == .solid && formatting.color == nil && fill.color.isAnimated {
            parameters.append(group("Face", key: "14", [
                param("Color", key: "16", fill.color, rgb), param("Opacity", key: "19", fill.color) { decimal($0.alpha) },
            ]))
        }

        let outline = style.outline
        if outline.isEnabled && (outline.color.isAnimated || outline.width.isAnimated) {
            parameters.append(group("Outline", key: "30", [
                param("Color", key: "32", outline.color, rgb), param("Opacity", key: "35", outline.color) { decimal($0.alpha) },
                param("Width", key: "36", outline.width, decimal),
            ]))
        }

        let shadow = style.shadow
        if shadow.isEnabled && (shadow.color.isAnimated || shadow.blur.isAnimated || shadow.offset.isAnimated) {
            parameters.append(group("Drop Shadow", key: "21", [
                param("Color", key: "23", shadow.color, rgb), param("Opacity", key: "26", shadow.color) { decimal($0.alpha) },
                param("Blur", key: "28", shadow.blur, decimal),
                param("Distance", key: "27", shadow.offset) { decimal(hypot($0.width, $0.height)) },
                param("Angle", key: "29", shadow.offset) { offset in
                    var angle = atan2(-offset.height, offset.width)
                    if angle < 0 { angle += 2 * .pi }
                    return decimal(offset == .zero ? 0 : angle)
                },
            ]))
        }
        return parameters
    }

    /// A setting as a `param`: its value at the start, and its keyframes,
    /// in the title's own time, which starts with the clip.
    private static func param<Value>(_ name: String, key: String, _ animatable: Animatable<Value>,
                                     _ format: (Value) -> String) -> MarkupElement {
        let keyframes = animatable.keyframes.map { keyframe in
            MarkupElement("keyframe", [
                ("time", InterchangeTime.string(keyframe.time)), ("value", format(keyframe.value)),
                ("interp", FCPXMLExporter.interp(keyframe.interpolation)),
            ])
        }
        return MarkupElement("param", [("name", name), ("key", key), ("value", format(animatable.value(at: .zero)))],
                             children: keyframes.isEmpty ? [] : [MarkupElement("keyframeAnimation", children: keyframes)])
    }

    private static func group(_ name: String, key: String, _ children: [MarkupElement]) -> MarkupElement {
        MarkupElement("param", [("name", name), ("key", key)], children: children)
    }

    /// The metadata key a title keeps Montage's own text under, as Montage
    /// saves it, so it comes back exactly with what Final Cut has no
    /// setting for, such as the background's padding.
    static let montageTextKey = "com.tsubuzaki.Montage.text"

    static func metadata(for text: TextContent) -> MarkupElement? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(text) else { return nil }
        return MarkupElement("metadata", children: [
            MarkupElement("md", [("key", montageTextKey), ("value", data.base64EncodedString())]),
        ])
    }

    /// Montage's own text kept in a title, if what Final Cut wrote of it
    /// still agrees: the same words, in the same font, size and alignment.
    private static func montageText(in title: MarkupElement, matching text: TextContent) -> TextContent? {
        guard let value = title.child("metadata")?.children("md").first(where: { $0["key"] == montageTextKey })?["value"],
              let data = Data(base64Encoded: value),
              let stored = try? JSONDecoder().decode(TextContent.self, from: data),
              stored.string == text.string else { return nil }
        let style = stored.style, read = text.style
        guard style.fontFamily == read.fontFamily, style.alignment == read.alignment,
              abs(style.fontSize.value(at: .zero) - read.fontSize.value(at: .zero)) < 0.001 else { return nil }
        return stored
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

    /// A colour as a Motion colour setting holds it, without its alpha,
    /// which is an opacity of its own.
    private static func rgb(_ color: RGBAColor) -> String {
        [color.red, color.green, color.blue].map(decimal).joined(separator: " ")
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
                let isAnimated = [definition, style].compactMap { $0 }.contains { element in
                    element.allDescendants.contains { $0.name == "keyframeAnimation" }
                }
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
            for name in ["baseline", "baselineOffset", "tabStops", "underline"] where attributes[name] != nil {
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
                         "shadowBlurRadius", "kerning", "lineSpacing", "alignment", "backgroundColor"] where attributes[name] != base[name] {
                note("Text style per word")
                break
            }
            runs.append(TextRun(piece.text, formatting: formatting))
        }
        let text = TextContent(runs: runs, style: style)
        if let stored = montageText(in: title, matching: text) { return Reading(text: stored) }
        return Reading(text: text, unsupported: unsupported)
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
        if let color = attributes["backgroundColor"].flatMap(color) {
            style.background.isEnabled = true
            style.background.color = Animatable(color)
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
        case "baselineOffset": return "Baseline offset"
        case "tabStops": return "Tab stops"
        default: return attribute.prefix(1).uppercased() + attribute.dropFirst()
        }
    }
}
