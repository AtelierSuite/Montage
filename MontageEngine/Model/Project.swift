import CoreGraphics
import CoreMedia
import Foundation

/// A video project: everything the user edits, and nothing derived from it.
/// Thumbnails, waveforms and proxies are caches beside it, made again from
/// the media whenever they're missing.
///
/// Value types all the way down, so a copy of the project is a snapshot:
/// undo keeps the project as it was, and playback and export each work from
/// a copy that edits can't change underneath them.
public struct Project: Equatable, Sendable {
    /// The version of the project format this build writes. Raise it, with a
    /// migration from the version before, whenever the model changes shape.
    public static let currentFormatVersion = 1

    /// The version of the project format the project was saved in.
    public var formatVersion: Int
    public var settings: ProjectSettings
    /// The media imported into the project, in the order the library lists it.
    public var media: [MediaItem]
    /// The library's bins, which media can be filed in, in the order they're listed.
    public var bins: [MediaBin]
    /// Video tracks first, bottom layer first, then audio tracks.
    public var tracks: [Track]
    /// Points marked on the timeline, in time order.
    public var markers: [Marker]
    /// The transitions at cuts between clips, in no particular order (see
    /// `placedTransitions(on:)` for where they play).
    public var transitions: [ClipTransition]

    public init(
        settings: ProjectSettings = ProjectSettings(), media: [MediaItem] = [], bins: [MediaBin] = [], tracks: [Track] = [],
        markers: [Marker] = [], transitions: [ClipTransition] = []
    ) {
        formatVersion = Self.currentFormatVersion
        self.settings = settings
        self.media = media
        self.bins = bins
        self.tracks = tracks
        self.markers = markers
        self.transitions = transitions
    }

    /// How long the project runs: to the end of its last clip.
    public var duration: CMTime {
        tracks.map(\.end).max() ?? .zero
    }

    public func mediaItem(id: MediaItem.ID) -> MediaItem? {
        media.first { $0.id == id }
    }

    /// The media item a clip is made from, if it's made from one.
    public func mediaItem(id: MediaItem.ID?) -> MediaItem? {
        id.flatMap { mediaItem(id: $0) }
    }

    /// Finds a clip on whichever track holds it.
    public func clip(id: Clip.ID) -> (track: Track, clip: Clip)? {
        for track in tracks {
            if let clip = track.clip(id: id) { return (track, clip) }
        }
        return nil
    }

    public func trackIndex(id: Track.ID) -> Int? {
        tracks.firstIndex { $0.id == id }
    }
}

extension Project: Codable {
    private enum CodingKeys: String, CodingKey {
        case formatVersion, settings, media, bins, tracks, markers, transitions
    }

    // Everything but the version is optional to read, so a project saved
    // before a part of the model existed still opens.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        settings = try container.decodeIfPresent(ProjectSettings.self, forKey: .settings) ?? ProjectSettings()
        media = try container.decodeIfPresent([MediaItem].self, forKey: .media) ?? []
        bins = try container.decodeIfPresent([MediaBin].self, forKey: .bins) ?? []
        tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) ?? []
        markers = try container.decodeIfPresent([Marker].self, forKey: .markers) ?? []
        transitions = try container.decodeIfPresent([ClipTransition].self, forKey: .transitions) ?? []
        markStillImageClips()
    }

    /// Makes clips of still images, saved before stills were content of
    /// their own, into image clips.
    private mutating func markStillImageClips() {
        let images = Set(media.filter { $0.kind == .image }.map(\.id))
        guard !images.isEmpty else { return }
        for index in tracks.indices {
            for clip in tracks[index].clips {
                guard case .media(let id) = clip.content, images.contains(id) else { continue }
                tracks[index].update(clip.id) { $0.content = .image(id) }
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(settings, forKey: .settings)
        try container.encode(media, forKey: .media)
        try container.encode(bins, forKey: .bins)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(markers, forKey: .markers)
        try container.encode(transitions, forKey: .transitions)
    }
}

/// The shape of the video the project makes.
public struct ProjectSettings: Equatable, Sendable {
    /// The frame's size, in pixels.
    public var renderSize: CGSize
    /// How long each frame lasts: 1/30 for 30 fps, 1001/30000 for 29.97.
    public var frameDuration: CMTime

    public init(renderSize: CGSize = CGSize(width: 1920, height: 1080), frameDuration: CMTime = CMTime(value: 1, timescale: 30)) {
        self.renderSize = renderSize
        self.frameDuration = frameDuration
    }

    public var frameRate: Double { 1 / frameDuration.seconds }
}

extension ProjectSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case renderSize, frameDuration
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ProjectSettings()
        renderSize = try container.decodeIfPresent(CGSize.self, forKey: .renderSize) ?? defaults.renderSize
        frameDuration = try container.contains(.frameDuration)
            ? container.decode(CMTime.self, forKey: .frameDuration) : defaults.frameDuration
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(renderSize, forKey: .renderSize)
        try container.encode(frameDuration, forKey: .frameDuration)
    }
}
