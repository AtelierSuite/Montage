import CoreMedia
import Foundation

/// What a clip shows or plays.
///
/// Media clips cut a stretch out of a video or a sound. Everything else is a
/// picture of its own with no time in it (a still image, text, a shape),
/// which the compositor draws over empty time for as long as the clip lasts.
public enum ClipContent: Equatable, Sendable {
    /// A stretch of a video or audio file in the library.
    case media(MediaItem.ID)
    /// A still image from the library.
    case image(MediaItem.ID)
    case text(TextContent)
    case shape(ShapeContent)

    /// The library item the clip is made from, if it's made from one.
    public var mediaID: MediaItem.ID? {
        switch self {
        case .media(let id), .image(let id): id
        case .text, .shape: nil
        }
    }

    /// Whether the clip has time of its own to trim against: only media
    /// does. Stills, text and shapes can be made any length.
    public var hasSourceTime: Bool {
        if case .media = self { return true }
        return false
    }

    /// Whether the compositor draws the clip itself, rather than taking its
    /// picture from a file: text and shapes.
    public var isGenerated: Bool {
        switch self {
        case .text, .shape: true
        case .media, .image: false
        }
    }

    public var text: TextContent? {
        if case .text(let text) = self { return text }
        return nil
    }

    public var shape: ShapeContent? {
        if case .shape(let shape) = self { return shape }
        return nil
    }

    /// The same content with every keyframe moved along by `offset`.
    func shifted(by offset: CMTime) -> ClipContent {
        switch self {
        case .media, .image: self
        case .text(let text): .text(text.shifted(by: offset))
        case .shape(let shape): .shape(shape.shifted(by: offset))
        }
    }
}

// Written as `{"media": id}`, `{"image": id}`, `{"text": {...}}` or
// `{"shape": {...}}`.
extension ClipContent: Codable {
    private enum CodingKeys: String, CodingKey {
        case media, image, text, shape
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let id = try container.decodeIfPresent(MediaItem.ID.self, forKey: .media) {
            self = .media(id)
        } else if let id = try container.decodeIfPresent(MediaItem.ID.self, forKey: .image) {
            self = .image(id)
        } else if let text = try container.decodeIfPresent(TextContent.self, forKey: .text) {
            self = .text(text)
        } else {
            self = .shape(try container.decode(ShapeContent.self, forKey: .shape))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .media(let id): try container.encode(id, forKey: .media)
        case .image(let id): try container.encode(id, forKey: .image)
        case .text(let text): try container.encode(text, forKey: .text)
        case .shape(let shape): try container.encode(shape, forKey: .shape)
        }
    }
}

/// How a picture of a different shape from the frame is fitted into it.
public enum FrameFit: String, Codable, Sendable, CaseIterable {
    /// All of the picture shows, centred, with bars where it doesn't reach.
    case fit
    /// The picture covers the frame, centred, cropped where it overflows.
    case fill
    /// The picture is stretched to the frame's shape.
    case stretch
}
