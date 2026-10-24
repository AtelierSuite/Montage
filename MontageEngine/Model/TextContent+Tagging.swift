import Foundation

/// Text clip words in a text editor, each character tagged with the
/// formatting it has. A text view carries the tag along as it would a
/// font, so typing takes on the formatting of the character before it, and
/// an edit anywhere leaves the formatting of the words it doesn't touch as
/// it was, however many places the words are edited in.
extension TextContent {
    /// The attribute a character's formatting is tagged under: its index
    /// among the formattings `tagged()` gives.
    public static let formattingAttribute = NSAttributedString.Key("MontageTextFormatting")

    /// The words, each piece tagged with its formatting, and the
    /// formattings the tags count among. There's always at least one, for
    /// typing into text that has no words yet.
    public func tagged() -> (string: NSAttributedString, formattings: [TextRun.Formatting]) {
        var formattings: [TextRun.Formatting] = []
        let string = NSMutableAttributedString()
        for run in runs {
            let index = formattings.firstIndex(of: run.formatting) ?? {
                formattings.append(run.formatting)
                return formattings.count - 1
            }()
            string.append(NSAttributedString(string: run.text, attributes: [Self.formattingAttribute: index]))
        }
        if formattings.isEmpty { formattings = [TextRun.Formatting()] }
        return (string, formattings)
    }

    /// Takes the words from tagged text, each piece keeping the formatting
    /// it's tagged with. Words with no tag, such as some pasted in, take on
    /// the formatting before them, or after them at the start.
    public mutating func setWords(from string: NSAttributedString, formattings: [TextRun.Formatting]) {
        var pieces: [(text: String, formatting: TextRun.Formatting?)] = []
        let whole = string.string as NSString
        string.enumerateAttribute(Self.formattingAttribute, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            let index = (value as? NSNumber)?.intValue ?? (value as? Int)
            let formatting = index.flatMap { formattings.indices.contains($0) ? formattings[$0] : nil }
            pieces.append((whole.substring(with: range), formatting))
        }
        let first = pieces.lazy.compactMap(\.formatting).first ?? TextRun.Formatting()
        var previous = first
        var runs: [TextRun] = []
        for piece in pieces {
            let formatting = piece.formatting ?? previous
            runs.append(TextRun(piece.text, formatting: formatting))
            previous = formatting
        }
        self = TextContent(runs: runs, style: style)
    }
}
