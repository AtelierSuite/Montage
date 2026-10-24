import CoreGraphics
import CoreMedia
import Foundation

/// Something placed on the timeline: a stretch of a media item, a still
/// image, text or a shape.
///
/// The clip takes `sourceRange` out of its media and plays it from
/// `timelineStart`. Content with no time of its own (a still, text, a
/// shape) only uses the range's duration. Its parameters' keyframes are timed from the clip's own
/// start, so moving the clip takes them with it.
public struct Clip: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var content: ClipContent
    /// The part of the media the clip plays, in the media's own time.
    public var sourceRange: CMTimeRange
    /// Where the clip starts on the timeline.
    public var timelineStart: CMTime

    /// 1 is the media's own level, 0 is silent.
    public var volume: Animatable<Double>
    /// 1 is opaque.
    public var opacity: Animatable<Double>
    public var transform: ClipTransform
    /// How the picture mixes with the layers under it.
    public var blendMode: BlendMode
    /// Whether the clip's audio has been split off into a clip of its own,
    /// so this one plays only its picture.
    public var isAudioDetached: Bool
    /// Applied in order.
    public var effects: [Effect]
    /// How the picture is fitted into the frame before it's transformed.
    public var fit: FrameFit

    /// A clip of a media item: a stretch of a video or a sound, or a still.
    public init(
        id: UUID = UUID(), mediaID: MediaItem.ID, sourceRange: CMTimeRange, timelineStart: CMTime = .zero,
        volume: Animatable<Double> = Animatable(1), opacity: Animatable<Double> = Animatable(1),
        transform: ClipTransform = ClipTransform(), blendMode: BlendMode = .normal, isAudioDetached: Bool = false,
        effects: [Effect] = []
    ) {
        self.init(
            id: id, content: .media(mediaID), sourceRange: sourceRange, timelineStart: timelineStart, volume: volume,
            opacity: opacity, transform: transform, blendMode: blendMode, isAudioDetached: isAudioDetached, effects: effects
        )
    }

    public init(
        id: UUID = UUID(), content: ClipContent, sourceRange: CMTimeRange, timelineStart: CMTime = .zero,
        volume: Animatable<Double> = Animatable(1), opacity: Animatable<Double> = Animatable(1),
        transform: ClipTransform = ClipTransform(), blendMode: BlendMode = .normal, isAudioDetached: Bool = false,
        effects: [Effect] = [], fit: FrameFit = .fit
    ) {
        self.id = id
        self.content = content
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.volume = volume
        self.opacity = opacity
        self.transform = transform
        self.blendMode = blendMode
        self.isAudioDetached = isAudioDetached
        self.effects = effects
        self.fit = fit
    }

    /// The library item the clip is made from; nil for text and shapes.
    public var mediaID: MediaItem.ID? { content.mediaID }

    public var duration: CMTime { sourceRange.duration }

    /// Where the clip sits on the timeline.
    public var timelineRange: CMTimeRange {
        CMTimeRange(start: timelineStart, duration: sourceRange.duration)
    }

    /// A time on the timeline, as a time from the clip's start: the time its
    /// keyframes are measured in.
    public func localTime(_ timelineTime: CMTime) -> CMTime {
        timelineTime - timelineStart
    }

    /// A time on the timeline, as a time in the clip's media.
    public func sourceTime(_ timelineTime: CMTime) -> CMTime {
        sourceRange.start + localTime(timelineTime)
    }
}

extension Clip: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, content, mediaID, sourceRange, timelineStart, volume, opacity, transform, blendMode, isAudioDetached,
             effects, fit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // Clips saved before there was anything but media name only their media.
        content = try container.decodeIfPresent(ClipContent.self, forKey: .content)
            ?? .media(try container.decode(MediaItem.ID.self, forKey: .mediaID))
        sourceRange = try container.decode(CMTimeRange.self, forKey: .sourceRange)
        timelineStart = try container.decode(CMTime.self, forKey: .timelineStart)
        volume = try container.decodeIfPresent(Animatable<Double>.self, forKey: .volume) ?? Animatable(1)
        opacity = try container.decodeIfPresent(Animatable<Double>.self, forKey: .opacity) ?? Animatable(1)
        transform = try container.decodeIfPresent(ClipTransform.self, forKey: .transform) ?? ClipTransform()
        blendMode = try container.decodeIfPresent(BlendMode.self, forKey: .blendMode) ?? .normal
        isAudioDetached = try container.decodeIfPresent(Bool.self, forKey: .isAudioDetached) ?? false
        effects = try container.decodeIfPresent([Effect].self, forKey: .effects) ?? []
        fit = try container.decodeIfPresent(FrameFit.self, forKey: .fit) ?? .fit
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(content, forKey: .content)
        // Builds from before content types read only this, so media clips
        // still open in them.
        try container.encodeIfPresent(content.mediaID, forKey: .mediaID)
        try container.encode(sourceRange, forKey: .sourceRange)
        try container.encode(timelineStart, forKey: .timelineStart)
        try container.encode(volume, forKey: .volume)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(transform, forKey: .transform)
        try container.encode(blendMode, forKey: .blendMode)
        try container.encode(isAudioDetached, forKey: .isAudioDetached)
        try container.encode(effects, forKey: .effects)
        try container.encode(fit, forKey: .fit)
    }
}

/// Where a clip's picture sits in the frame. The identity fits the picture
/// into the frame, centred, keeping its shape.
public struct ClipTransform: Equatable, Sendable, Codable {
    /// The picture's centre, as a fraction of the frame: (0.5, 0.5) is the
    /// middle, (0, 0) the top-left corner.
    public var position = Animatable(CGPoint(x: 0.5, y: 0.5))
    /// 1 fits the frame.
    public var scale = Animatable(1.0)
    /// Clockwise, in degrees.
    public var rotation = Animatable(0.0)

    public init() {}
}
