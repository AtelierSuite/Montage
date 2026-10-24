import CoreGraphics
import CoreMedia
import Foundation

/// A text clip's words and how they look.
///
/// The words are a run of pieces, each of which can be bolder, slanted or
/// coloured differently from the clip's style, so one word can stand out.
/// Everything else (the font, its size, colour, outline, shadow and box) is
/// the style's, for the whole clip, and the numbers and colours in it can be
/// keyframed.
public struct TextContent: Equatable, Sendable, Codable {
    /// The words, piece by piece, in order.
    public var runs: [TextRun]
    public var style: TextStyle

    public init(_ string: String = "", style: TextStyle = TextStyle()) {
        runs = string.isEmpty ? [] : [TextRun(string)]
        self.style = style
    }

    public init(runs: [TextRun], style: TextStyle = TextStyle()) {
        self.runs = runs
        self.style = style
        normalizeRuns()
    }

    /// The words, without their formatting.
    public var string: String {
        runs.map(\.text).joined()
    }

    func shifted(by offset: CMTime) -> TextContent {
        var text = self
        text.style = style.shifted(by: offset)
        return text
    }

    // MARK: - Editing

    /// Changes the words, keeping each piece's formatting where the words
    /// it covers are kept. New words take the formatting of the ones before
    /// them, or after them at the very start.
    public mutating func replaceString(with newString: String) {
        let old = formattedCharacters
        let oldCharacters = old.map(\.character)
        let newCharacters = Array(newString)
        var prefix = 0
        while prefix < oldCharacters.count, prefix < newCharacters.count, oldCharacters[prefix] == newCharacters[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < oldCharacters.count - prefix, suffix < newCharacters.count - prefix,
              oldCharacters[oldCharacters.count - 1 - suffix] == newCharacters[newCharacters.count - 1 - suffix] {
            suffix += 1
        }
        let inserted = newCharacters[prefix..<(newCharacters.count - suffix)]
        // Typed over or before the first character, words take its formatting.
        let formatting = prefix > 0 ? old[prefix - 1].formatting : old.first?.formatting ?? TextRun.Formatting()
        var result = Array(old[..<prefix])
        result += inserted.map { (character: $0, formatting: formatting) }
        result += old[(old.count - suffix)...]
        setFormattedCharacters(result)
    }

    /// Changes the formatting of the characters in a range, counted in
    /// characters from the start.
    public mutating func format(_ range: Range<Int>, _ change: (inout TextRun.Formatting) -> Void) {
        var characters = formattedCharacters
        let range = range.clamped(to: 0..<characters.count)
        for index in range { change(&characters[index].formatting) }
        setFormattedCharacters(characters)
    }

    /// The formatting the characters in a range share, field by field: a
    /// field is nil where they differ or none of them set it.
    public func formatting(in range: Range<Int>) -> TextRun.Formatting {
        let characters = formattedCharacters
        let range = range.clamped(to: 0..<characters.count)
        let picked = range.isEmpty
            ? [characters.indices.contains(range.lowerBound - 1) ? characters[range.lowerBound - 1].formatting
                : characters.first?.formatting ?? TextRun.Formatting()]
            : characters[range].map(\.formatting)
        guard var shared = picked.first else { return TextRun.Formatting() }
        for formatting in picked.dropFirst() {
            if formatting.weight != shared.weight { shared.weight = nil }
            if formatting.isItalic != shared.isItalic { shared.isItalic = nil }
            if formatting.color != shared.color { shared.color = nil }
        }
        return shared
    }

    private var formattedCharacters: [(character: Character, formatting: TextRun.Formatting)] {
        runs.flatMap { run in run.text.map { (character: $0, formatting: run.formatting) } }
    }

    private mutating func setFormattedCharacters(_ characters: [(character: Character, formatting: TextRun.Formatting)]) {
        runs = characters.map { TextRun(String($0.character), formatting: $0.formatting) }
        normalizeRuns()
    }

    /// Joins neighbouring pieces formatted alike, and drops empty ones.
    private mutating func normalizeRuns() {
        var merged: [TextRun] = []
        for run in runs where !run.text.isEmpty {
            if let last = merged.last, last.formatting == run.formatting {
                merged[merged.count - 1].text += run.text
            } else {
                merged.append(run)
            }
        }
        runs = merged
    }

    // MARK: - Values at a time

    /// Everything needed to draw the text at a time: the same values always
    /// draw the same picture, so it's what drawn pictures are cached by.
    public struct Resolved: Hashable, Sendable {
        public var runs: [TextRun]
        public var fontFamily: String
        public var fontSize: Double
        public var weight: FontWeight
        public var isItalic: Bool
        public var fill: LayerFill.Resolved
        public var alignment: TextAlignment
        public var lineSpacing: Double
        public var letterSpacing: Double
        public var outline: LayerStroke.Resolved?
        public var shadow: LayerShadow.Resolved?
        public var background: TextBackground.Resolved?
        /// How wide a line can get before it wraps.
        public var wrapWidth: Double
    }

    /// The text's values at a time from the clip's start, laid out in a
    /// frame of `renderSize`.
    public func resolved(at time: CMTime, renderSize: CGSize) -> Resolved {
        Resolved(
            runs: runs, fontFamily: style.fontFamily, fontSize: max(1, style.fontSize.value(at: time)),
            weight: style.weight, isItalic: style.isItalic, fill: style.fill.resolved(at: time),
            alignment: style.alignment, lineSpacing: style.lineSpacing.value(at: time),
            letterSpacing: style.letterSpacing.value(at: time), outline: style.outline.resolved(at: time),
            shadow: style.shadow.resolved(at: time), background: style.background.resolved(at: time),
            wrapWidth: max(1, renderSize.width * style.wrapWidth)
        )
    }
}

/// A piece of a text clip's words, formatted alike.
public struct TextRun: Equatable, Hashable, Sendable, Codable {
    /// How a piece differs from the clip's style. Nil leaves the style's.
    public struct Formatting: Equatable, Hashable, Sendable, Codable {
        public var weight: FontWeight?
        public var isItalic: Bool?
        /// Used when the text is filled with a solid colour.
        public var color: RGBAColor?

        public init(weight: FontWeight? = nil, isItalic: Bool? = nil, color: RGBAColor? = nil) {
            self.weight = weight
            self.isItalic = isItalic
            self.color = color
        }
    }

    public var text: String
    public var formatting: Formatting

    public init(_ text: String, formatting: Formatting = Formatting()) {
        self.text = text
        self.formatting = formatting
    }
}

/// How heavy a font's strokes are.
public enum FontWeight: String, Codable, Sendable, CaseIterable, Comparable {
    case ultraLight, thin, light, regular, medium, semibold, bold, heavy, black

    /// Core Text's weight trait, from -1 to 1, 0 being regular.
    public var trait: Double {
        switch self {
        case .ultraLight: -0.8
        case .thin: -0.6
        case .light: -0.4
        case .regular: 0
        case .medium: 0.23
        case .semibold: 0.3
        case .bold: 0.4
        case .heavy: 0.56
        case .black: 0.62
        }
    }

    public static func < (lhs: FontWeight, rhs: FontWeight) -> Bool {
        lhs.trait < rhs.trait
    }
}

/// How the lines of a text clip line up with each other.
public enum TextAlignment: String, Codable, Sendable, CaseIterable {
    case leading, center, trailing
}

/// A box behind text, so it reads over any picture.
public struct TextBackground: Equatable, Sendable, Codable {
    public var isEnabled: Bool
    public var color: Animatable<RGBAColor>
    /// The room between the text and the box's edge, in the frame's pixels.
    public var padding: Animatable<Double>
    public var cornerRadius: Animatable<Double>

    public init(
        isEnabled: Bool = false, color: RGBAColor = RGBAColor(white: 0, alpha: 0.6), padding: Double = 24,
        cornerRadius: Double = 12
    ) {
        self.isEnabled = isEnabled
        self.color = Animatable(color)
        self.padding = Animatable(padding)
        self.cornerRadius = Animatable(cornerRadius)
    }

    func shifted(by offset: CMTime) -> TextBackground {
        var background = self
        background.color = color.shifted(by: offset)
        background.padding = padding.shifted(by: offset)
        background.cornerRadius = cornerRadius.shifted(by: offset)
        return background
    }

    public struct Resolved: Hashable, Sendable {
        public var color: RGBAColor
        public var padding: Double
        public var cornerRadius: Double
    }

    public func resolved(at time: CMTime) -> Resolved? {
        guard isEnabled else { return nil }
        return Resolved(
            color: color.value(at: time), padding: max(0, padding.value(at: time)),
            cornerRadius: max(0, cornerRadius.value(at: time))
        )
    }
}

/// How a text clip looks, for the whole clip. Sizes are in the project's
/// frame's pixels, so text keeps its size against the picture whatever size
/// it's shown at.
public struct TextStyle: Equatable, Sendable, Codable {
    /// The font family's name, such as "Helvetica Neue".
    public var fontFamily: String
    public var fontSize: Animatable<Double>
    public var weight: FontWeight
    public var isItalic: Bool
    public var fill: LayerFill
    public var alignment: TextAlignment
    /// Room added between lines.
    public var lineSpacing: Animatable<Double>
    /// Room added between letters.
    public var letterSpacing: Animatable<Double>
    public var outline: LayerStroke
    public var shadow: LayerShadow
    public var background: TextBackground
    /// How wide a line can get before it wraps, as a fraction of the frame's
    /// width.
    public var wrapWidth: Double

    public init(
        fontFamily: String = TextStyle.defaultFontFamily, fontSize: Double = 96, weight: FontWeight = .bold,
        isItalic: Bool = false, fill: LayerFill = LayerFill(), alignment: TextAlignment = .center,
        lineSpacing: Double = 0, letterSpacing: Double = 0, outline: LayerStroke = LayerStroke(),
        shadow: LayerShadow = LayerShadow(), background: TextBackground = TextBackground(), wrapWidth: Double = 0.9
    ) {
        self.fontFamily = fontFamily
        self.fontSize = Animatable(fontSize)
        self.weight = weight
        self.isItalic = isItalic
        self.fill = fill
        self.alignment = alignment
        self.lineSpacing = Animatable(lineSpacing)
        self.letterSpacing = Animatable(letterSpacing)
        self.outline = outline
        self.shadow = shadow
        self.background = background
        self.wrapWidth = wrapWidth
    }

    /// A family every Apple platform has.
    public static let defaultFontFamily = "Helvetica Neue"

    func shifted(by offset: CMTime) -> TextStyle {
        var style = self
        style.fontSize = fontSize.shifted(by: offset)
        style.fill = fill.shifted(by: offset)
        style.lineSpacing = lineSpacing.shifted(by: offset)
        style.letterSpacing = letterSpacing.shifted(by: offset)
        style.outline = outline.shifted(by: offset)
        style.shadow = shadow.shifted(by: offset)
        style.background = background.shifted(by: offset)
        return style
    }

    /// The style as it is at a time, with no keyframes: what a preset keeps.
    public func flattened(at time: CMTime) -> TextStyle {
        var style = self
        style.fontSize = Animatable(fontSize.value(at: time))
        style.fill.color = Animatable(fill.color.value(at: time))
        style.fill.endColor = Animatable(fill.endColor.value(at: time))
        style.fill.angle = Animatable(fill.angle.value(at: time))
        style.lineSpacing = Animatable(lineSpacing.value(at: time))
        style.letterSpacing = Animatable(letterSpacing.value(at: time))
        style.outline.color = Animatable(outline.color.value(at: time))
        style.outline.width = Animatable(outline.width.value(at: time))
        style.shadow.color = Animatable(shadow.color.value(at: time))
        style.shadow.blur = Animatable(shadow.blur.value(at: time))
        style.shadow.offset = Animatable(shadow.offset.value(at: time))
        style.background.color = Animatable(background.color.value(at: time))
        style.background.padding = Animatable(background.padding.value(at: time))
        style.background.cornerRadius = Animatable(background.cornerRadius.value(at: time))
        return style
    }
}
