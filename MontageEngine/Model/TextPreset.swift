import CoreGraphics
import CoreMedia
import Foundation

/// A look for text that can be put on any text clip: its style, and where in
/// the frame it goes.
public struct TextPreset: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var style: TextStyle
    /// The text's centre, as a fraction of the frame.
    public var position: CGPoint

    public init(id: UUID = UUID(), name: String, style: TextStyle, position: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.id = id
        self.name = name
        self.style = style
        self.position = position
    }

    /// A preset of a clip's text as it looks at a time, keyframes left out.
    public init?(name: String, from clip: Clip, at time: CMTime) {
        guard let text = clip.content.text else { return nil }
        self.init(name: name, style: text.style.flattened(at: time), position: clip.transform.position.value(at: time))
    }
}

/// The looks every project starts with.
public enum BuiltInTextPreset: String, CaseIterable, Sendable {
    case title, lowerThird, caption, subtitle

    public var style: TextStyle {
        switch self {
        case .title:
            var style = TextStyle(fontSize: 140, weight: .heavy)
            style.shadow = LayerShadow(isEnabled: true, blur: 18, offset: CGSize(width: 0, height: 8))
            return style
        case .lowerThird:
            var style = TextStyle(fontSize: 56, weight: .semibold, alignment: .leading, wrapWidth: 0.6)
            style.background = TextBackground(isEnabled: true, color: RGBAColor(red: 0.05, green: 0.1, blue: 0.25, alpha: 0.85),
                                              padding: 28, cornerRadius: 8)
            return style
        case .caption:
            var style = TextStyle(fontSize: 44, weight: .medium, wrapWidth: 0.8)
            style.background = TextBackground(isEnabled: true, color: RGBAColor(white: 0, alpha: 0.55), padding: 16, cornerRadius: 10)
            return style
        case .subtitle:
            var style = TextStyle(fontSize: 52, weight: .semibold, wrapWidth: 0.85)
            style.outline = LayerStroke(isEnabled: true, color: .black, width: 4)
            return style
        }
    }

    /// Where in the frame it goes.
    public var position: CGPoint {
        switch self {
        case .title: CGPoint(x: 0.5, y: 0.45)
        case .lowerThird: CGPoint(x: 0.3, y: 0.8)
        case .caption: CGPoint(x: 0.5, y: 0.85)
        case .subtitle: CGPoint(x: 0.5, y: 0.88)
        }
    }
}

extension Clip {
    /// Gives a text clip a preset's style, and puts it where the preset goes.
    public mutating func apply(_ style: TextStyle, position: CGPoint) {
        guard case .text(var text) = content else { return }
        text.style = style
        content = .text(text)
        transform.position = Animatable(position)
    }
}
