import CoreMedia
import Foundation

/// A row of the timeline. Clips on a track don't overlap and are kept in
/// timeline order. Video tracks stack: later tracks draw over earlier ones.
public struct Track: Identifiable, Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case video, audio
    }

    public var id: UUID
    public var kind: Kind
    public private(set) var clips: [Clip]
    /// Muted, a track's audio is left out of playback and export.
    public var isMuted: Bool
    /// Hidden, a video track's picture is left out of playback and export.
    public var isHidden: Bool

    public init(id: UUID = UUID(), kind: Kind, clips: [Clip] = [], isMuted: Bool = false, isHidden: Bool = false) {
        self.id = id
        self.kind = kind
        self.clips = clips.sorted { $0.timelineStart < $1.timelineStart }
        self.isMuted = isMuted
        self.isHidden = isHidden
    }

    /// Where the track's last clip ends.
    public var end: CMTime {
        clips.map(\.timelineRange.end).max() ?? .zero
    }

    public func clip(id: Clip.ID) -> Clip? {
        clips.first { $0.id == id }
    }

    /// The clips that share some time with a range, such as one a selection
    /// rectangle is drawn across. Clips that only touch it at an end are
    /// left out. An empty range takes the clip it's in, if any.
    public func clips(overlapping range: CMTimeRange) -> [Clip] {
        let start = range.start
        let end = range.end
        if end <= start {
            return clips.filter { $0.timelineStart <= start && start < $0.timelineRange.end }
        }
        return clips.filter { $0.timelineStart < end && start < $0.timelineRange.end }
    }

    /// Adds a clip, keeping the clips in timeline order. The caller makes
    /// room for it first; overlapping clips aren't resolved here.
    public mutating func insert(_ clip: Clip) {
        let index = clips.firstIndex { $0.timelineStart > clip.timelineStart } ?? clips.endIndex
        clips.insert(clip, at: index)
    }

    /// Puts a clip at the end of the track.
    public mutating func append(_ clip: Clip) {
        var clip = clip
        clip.timelineStart = end
        clips.append(clip)
    }

    /// Changes a clip in place, then puts the clips back in order in case
    /// it moved.
    public mutating func update(_ id: Clip.ID, _ change: (inout Clip) -> Void) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        change(&clips[index])
        clips.sort { $0.timelineStart < $1.timelineStart }
    }

    /// Changes every clip in place, then puts the clips back in order once,
    /// rather than once for each clip as `update` would.
    mutating func updateEach(_ change: (inout Clip) -> Void) {
        for index in clips.indices {
            change(&clips[index])
        }
        clips.sort { $0.timelineStart < $1.timelineStart }
    }

    @discardableResult
    public mutating func remove(_ id: Clip.ID) -> Clip? {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return nil }
        return clips.remove(at: index)
    }

    // Decoded by hand so the clips are back in order whatever the file says.
    private enum CodingKeys: String, CodingKey {
        case id, kind, clips, isMuted, isHidden
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            kind: try container.decode(Kind.self, forKey: .kind),
            clips: try container.decodeIfPresent([Clip].self, forKey: .clips) ?? [],
            isMuted: try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false,
            isHidden: try container.decodeIfPresent(Bool.self, forKey: .isHidden) ?? false
        )
    }
}
