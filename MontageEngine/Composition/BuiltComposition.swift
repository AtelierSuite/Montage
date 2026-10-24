import AVFoundation
import CoreMedia

/// A project turned into AVFoundation objects, ready to play or export.
///
/// Preview and export use the very same objects, so what plays is what is
/// written: hand `composition`, `videoComposition` and `audioMix` to an
/// `AVPlayerItem` (see `makePlayerItem()`) or to an exporter as they are.
///
/// Every object here is an immutable copy made at the end of the build, so the
/// value can cross actors freely even though AVFoundation doesn't mark all of
/// them `Sendable`.
public struct BuiltComposition: @unchecked Sendable {
    /// The project as it was when this was built.
    public let project: Project
    /// What plays when: one video track per visible video layer and one audio
    /// track per audible track of the timeline, with empty time in the gaps
    /// and filler under stills, text and shapes (see `StillFiller`).
    public let composition: AVComposition
    /// How the video tracks are laid into the frame. Nil when nothing in the
    /// composition has a picture.
    public let videoComposition: AVVideoComposition?
    /// The clips' volumes, and the taps that run their audio effects. Nil
    /// when nothing in the composition makes a sound.
    public let audioMix: AVAudioMix?
    /// How long the composition runs: to the end of the last clip placed, gaps
    /// included. Shorter than the project when clips at the end were left out.
    public let duration: CMTime
    /// Which composition tracks carry which clips' pictures, bottom layer
    /// first.
    public let videoLayers: [CompositionLayer]
    /// Which composition tracks carry which clips' sound.
    public let audioLayers: [CompositionLayer]
    /// Clips that were left out, and why.
    public let skippedClips: [SkippedClip]
    /// How loud each clip's sound is as it plays, after its effects.
    public let audioLevels: AudioLevels

    init(
        project: Project, composition: AVComposition, videoComposition: AVVideoComposition?, audioMix: AVAudioMix?,
        duration: CMTime, videoLayers: [CompositionLayer], audioLayers: [CompositionLayer], skippedClips: [SkippedClip],
        audioLevels: AudioLevels = AudioLevels()
    ) {
        self.project = project
        self.composition = composition
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.duration = duration
        self.videoLayers = videoLayers
        self.audioLayers = audioLayers
        self.skippedClips = skippedClips
        self.audioLevels = audioLevels
    }

    /// Whether there's nothing to play: no clip made it into the composition.
    public var isEmpty: Bool { videoLayers.isEmpty && audioLayers.isEmpty }

    /// Media whose file couldn't be found or read, each listed once in the
    /// order its first clip came up. Clips on it play as empty time, unless
    /// they're at the very end.
    public var missingMedia: [MediaItem.ID] {
        var seen = Set<MediaItem.ID>()
        return skippedClips.filter(\.reason.isMissingMedia).compactMap(\.mediaID).filter { seen.insert($0).inserted }
    }

    /// The video layers with a clip showing at a time, bottom layer first,
    /// each with the part of the clip that covers the time.
    public func videoSegments(at time: CMTime) -> [(layer: CompositionLayer, segment: CompositionLayer.Segment)] {
        videoLayers.compactMap { layer in layer.segment(at: time).map { (layer, $0) } }
    }

    /// A player item that plays the composition with its video composition
    /// and audio mix.
    @MainActor
    public func makePlayerItem() -> AVPlayerItem {
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        item.audioMix = audioMix
        return item
    }
}

/// One composition track and the clips placed on it: the map a custom
/// compositor or audio tap uses to get from a composition track ID back to
/// the model's clips, and so to their parameters.
public struct CompositionLayer: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case video, audio
    }

    public var kind: Kind
    /// The timeline track the clips are on.
    public var trackID: Track.ID
    /// The composition track that carries them.
    public var compositionTrackID: CMPersistentTrackID
    /// The clips' stretches in timeline order, as far as each was placed.
    public var segments: [Segment]

    /// A clip, or as much of it as its media has, on the composition track.
    public struct Segment: Equatable, Sendable {
        public var clipID: Clip.ID
        /// The media it's made from; nil for text and shapes.
        public var mediaID: MediaItem.ID?
        /// Where it plays, in composition (timeline) time.
        public var timelineRange: CMTimeRange
        /// What of the media plays there, in the media's own time.
        public var sourceRange: CMTimeRange
    }

    /// The segment playing at a time, if any.
    public func segment(at time: CMTime) -> Segment? {
        segments.first { $0.timelineRange.start <= time && time < $0.timelineRange.end }
    }
}

/// A clip the builder couldn't put into the composition.
public struct SkippedClip: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The clip points at media the project doesn't have.
        case mediaNotInProject
        /// The media's file couldn't be found.
        case fileNotFound
        /// The file is there, but couldn't be opened as media.
        case unreadable
        /// The media has nothing the clip's track plays: no picture for a
        /// video track, no sound for an audio track.
        case noUsableTrack
        /// The clip's source range lies outside its media.
        case outsideMedia
        /// More video layers would show along the clip than the device can
        /// decode at once (see `VideoLayerLimit`). Its sound still plays.
        case tooManyLayers

        /// Whether the clip's media itself is missing, rather than the clip
        /// being something the composition can't hold.
        public var isMissingMedia: Bool {
            switch self {
            case .mediaNotInProject, .fileNotFound, .unreadable: true
            case .noUsableTrack, .outsideMedia, .tooManyLayers: false
            }
        }
    }

    public var clipID: Clip.ID
    /// The media it's made from; nil for text and shapes.
    public var mediaID: MediaItem.ID?
    public var reason: Reason
}
