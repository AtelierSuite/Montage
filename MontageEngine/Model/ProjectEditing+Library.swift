import CoreMedia
import Foundation

/// The library's bookkeeping: which media the timeline uses, bins, and
/// dropping media onto the timeline at a time.
extension Project {
    // MARK: - Use

    /// The media with at least one clip on the timeline.
    public var usedMediaIDs: Set<MediaItem.ID> {
        Set(tracks.flatMap { $0.clips.compactMap(\.mediaID) })
    }

    /// How many clips on the timeline are made from each media item. Items
    /// with none aren't listed.
    public var clipCounts: [MediaItem.ID: Int] {
        tracks.flatMap(\.clips).reduce(into: [:]) { counts, clip in if let id = clip.mediaID { counts[id, default: 0] += 1 } }
    }

    /// The clips made from any of `mediaIDs`, earliest on the timeline
    /// first.
    public func clips(usingMedia mediaIDs: Set<MediaItem.ID>) -> [Clip] {
        tracks.flatMap(\.clips)
            .filter { $0.mediaID.map(mediaIDs.contains) ?? false }
            .sorted { $0.timelineStart < $1.timelineStart }
    }

    /// The media with no clip on the timeline, in library order.
    public var unusedMedia: [MediaItem] {
        let used = usedMediaIDs
        return media.filter { !used.contains($0.id) }
    }

    /// Takes every item the timeline doesn't use out of the library. Returns
    /// their IDs.
    @discardableResult
    public mutating func removeUnusedMedia() -> Set<MediaItem.ID> {
        let unused = Set(unusedMedia.map(\.id))
        media.removeAll { unused.contains($0.id) }
        return unused
    }

    // MARK: - Bins

    /// Adds a bin at the end of the list, and returns its ID.
    @discardableResult
    public mutating func addBin(named name: String) -> MediaBin.ID {
        let bin = MediaBin(name: name)
        bins.append(bin)
        return bin.id
    }

    public mutating func renameBin(_ id: MediaBin.ID, to name: String) {
        guard let index = bins.firstIndex(where: { $0.id == id }) else { return }
        bins[index].name = name
    }

    /// Takes a bin away. The media filed in it stays in the library, filed
    /// in no bin.
    public mutating func removeBin(_ id: MediaBin.ID) {
        bins.removeAll { $0.id == id }
        for index in media.indices where media[index].binID == id {
            media[index].binID = nil
        }
    }

    /// Files media in a bin, or in none with nil. A bin the project doesn't
    /// have files nothing.
    public mutating func moveMedia(_ ids: Set<MediaItem.ID>, toBin binID: MediaBin.ID?) {
        if let binID, !bins.contains(where: { $0.id == binID }) { return }
        for index in media.indices where ids.contains(media[index].id) {
            media[index].binID = binID
        }
    }

    // MARK: - Dropping onto the timeline

    /// Puts the whole of each media item on the timeline one after another
    /// from `time`, as a drop from the library does. Each goes on `trackID`
    /// if that's a track of its kind with room for it there, else on the
    /// first track of its kind with room, else on a new track of its kind:
    /// a drop never covers clips that are already there. Returns the new
    /// clips' IDs.
    @discardableResult
    public mutating func insertClips(
        of mediaIDs: [MediaItem.ID], at time: CMTime, onTrack trackID: Track.ID? = nil
    ) -> [Clip.ID] {
        var start = time.isNumeric ? CMTimeMaximum(time, .zero) : .zero
        var added: [Clip.ID] = []
        for id in mediaIDs {
            guard let item = mediaItem(id: id) else { continue }
            let duration = item.kind == .image ? Self.defaultImageDuration : item.metadata.duration
            guard duration.isNumeric, duration > .zero else { continue }
            let clip = Clip(content: item.content, sourceRange: CMTimeRange(start: .zero, duration: duration), timelineStart: start)
            let index = trackIndex(for: Self.trackKind(for: item.kind), fitting: clip.timelineRange, preferring: trackID)
            tracks[index].insert(clip)
            added.append(clip.id)
            start = clip.timelineRange.end
        }
        return added
    }

    /// Where `insertClips(of:at:onTrack:)` would put each item, without
    /// putting it there: for the timeline to show a drop before it's made.
    public func placements(
        ofClipsOf mediaIDs: [MediaItem.ID], at time: CMTime, onTrack trackID: Track.ID? = nil
    ) -> [ClipPlacement] {
        var project = self
        let existing = Set(tracks.map(\.id))
        return project.insertClips(of: mediaIDs, at: time, onTrack: trackID).compactMap { id in
            guard let (track, clip) = project.clip(id: id), let mediaID = clip.mediaID else { return nil }
            return ClipPlacement(
                mediaID: mediaID, trackID: track.id, kind: track.kind, isNewTrack: !existing.contains(track.id),
                range: clip.timelineRange
            )
        }
    }

    /// Puts a clip of text or a shape on the timeline at `time`, lasting
    /// `duration`, over whatever video is there: on the first video track
    /// above the clips under it with room, or a new track on top. Hidden
    /// tracks are passed over, since nothing on them shows. Returns the new
    /// clip's ID.
    @discardableResult
    public mutating func insertClip(
        of content: ClipContent, at time: CMTime, duration: CMTime = Project.defaultImageDuration
    ) -> Clip.ID {
        let start = time.isNumeric ? CMTimeMaximum(time, .zero) : .zero
        let clip = Clip(content: content, sourceRange: CMTimeRange(start: .zero, duration: duration), timelineStart: start)
        let range = clip.timelineRange
        func isFree(_ index: Int) -> Bool {
            !tracks[index].clips.contains { !$0.timelineRange.intersection(range).isEmpty }
        }
        let video = tracks.indices.filter { tracks[$0].kind == .video }
        let visible = video.filter { !tracks[$0].isHidden }
        let covered = visible.last { !isFree($0) }
        let index = visible.first { $0 > (covered ?? -1) && isFree($0) } ?? {
            let index = video.last.map { $0 + 1 } ?? tracks.firstIndex { $0.kind == .audio } ?? tracks.endIndex
            tracks.insert(Track(kind: .video), at: index)
            return index
        }()
        tracks[index].insert(clip)
        return clip.id
    }

    /// A track of a kind that's empty over `range`: the preferred one, the
    /// first of the kind, or a new one after the last of its kind.
    private mutating func trackIndex(for kind: Track.Kind, fitting range: CMTimeRange, preferring trackID: Track.ID?) -> Int {
        func fits(_ track: Track) -> Bool {
            track.kind == kind && !track.clips.contains { !$0.timelineRange.intersection(range).isEmpty }
        }
        if let trackID, let index = self.trackIndex(id: trackID), fits(tracks[index]) { return index }
        if let index = tracks.firstIndex(where: fits) { return index }
        let index = kind == .video
            ? (tracks.lastIndex { $0.kind == .video }.map { $0 + 1 } ?? tracks.firstIndex { $0.kind == .audio } ?? tracks.endIndex)
            : tracks.endIndex
        tracks.insert(Track(kind: kind), at: index)
        return index
    }
}

/// Where a clip of a media item would go on the timeline.
public struct ClipPlacement: Equatable, Sendable {
    public var mediaID: MediaItem.ID
    /// The track it goes on. A new track's ID is made up for the placement,
    /// and isn't the one the drop makes.
    public var trackID: Track.ID
    public var kind: Track.Kind
    /// Whether the track is one the drop would add.
    public var isNewTrack: Bool
    public var range: CMTimeRange

    public init(mediaID: MediaItem.ID, trackID: Track.ID, kind: Track.Kind, isNewTrack: Bool, range: CMTimeRange) {
        self.mediaID = mediaID
        self.trackID = trackID
        self.kind = kind
        self.isNewTrack = isNewTrack
        self.range = range
    }
}
