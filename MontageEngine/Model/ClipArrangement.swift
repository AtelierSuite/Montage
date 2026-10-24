import CoreMedia
import Foundation

/// Moving clips about the timeline, taking them off it, and splitting their
/// sound off.
extension Project {
    /// Moves clips along the timeline by an offset, and onto other tracks of
    /// the same kind. A clip goes where it's put: whatever it lands on is cut
    /// away under it, the way an overwrite edit works, rather than the clip
    /// being turned back.
    ///
    /// `trackOffsets` says, for each kind of track, how many tracks along to
    /// move: up a layer for video, down a row for audio. A clip moved past
    /// the last track of its kind makes one new track for it there, and one
    /// moved past the first stays on the first. Clips keep their places
    /// relative to one another, and none is moved to before the timeline's
    /// start.
    public mutating func moveClips(_ ids: Set<Clip.ID>, by offset: CMTime, trackOffsets: [Track.Kind: Int] = [:]) {
        let moving = tracks.enumerated().flatMap { index, track in
            track.clips.filter { ids.contains($0.id) }.map { (trackIndex: index, clip: $0) }
        }
        guard !moving.isEmpty else { return }
        let earliest = moving.map(\.clip.timelineStart).min() ?? .zero
        let offset = max(offset, .zero - earliest)

        // Each clip's track as a place among the tracks of its kind, moved
        // along, kept within them and at most one past the last.
        var destinations: [(clip: Clip, kind: Track.Kind, place: Int)] = []
        for kind in [Track.Kind.video, .audio] {
            let ofKind = tracks.indices.filter { tracks[$0].kind == kind }
            let places = moving.compactMap { item in ofKind.firstIndex(of: item.trackIndex).map { (item.clip, $0) } }
            guard let lowest = places.map(\.1).min(), let highest = places.map(\.1).max() else { continue }
            let trackOffset = min(max(trackOffsets[kind] ?? 0, -lowest), ofKind.count - highest)
            destinations += places.map { ($0.0, kind, $0.1 + trackOffset) }
        }

        for item in moving { tracks[item.trackIndex].remove(item.clip.id) }
        var newTracks: [Track.Kind: Track.ID] = [:]
        for destination in destinations.sorted(by: { $0.clip.timelineStart < $1.clip.timelineStart }) {
            let ofKind = tracks.indices.filter { tracks[$0].kind == destination.kind }
            let index: Int
            if destination.place < ofKind.count {
                index = ofKind[destination.place]
            } else if let id = newTracks[destination.kind], let existing = trackIndex(id: id) {
                index = existing
            } else {
                index = insertTrack(of: destination.kind)
                newTracks[destination.kind] = tracks[index].id
            }
            var clip = destination.clip
            clip.timelineStart = clip.timelineStart + offset
            clearRange(clip.timelineRange, onTrackAt: index)
            tracks[index].insert(clip)
        }
    }

    /// Adds an empty track of a kind after the others of its kind, keeping
    /// video tracks before audio tracks, and returns its index.
    @discardableResult
    public mutating func insertTrack(of kind: Track.Kind) -> Int {
        let index = switch kind {
        case .video: tracks.firstIndex { $0.kind == .audio } ?? tracks.endIndex
        case .audio: tracks.endIndex
        }
        tracks.insert(Track(kind: kind), at: index)
        return index
    }

    /// Makes a stretch of a track empty: clips inside it are taken off, and
    /// clips reaching into it are trimmed back to it, or cut in two around it.
    public mutating func clearRange(_ range: CMTimeRange, onTrackAt index: Int) {
        guard range.duration > .zero else { return }
        for clip in tracks[index].clips {
            let clipRange = clip.timelineRange
            guard clipRange.start < range.end, clipRange.end > range.start else { continue }
            let isStill = isStill(clip)
            if clipRange.start >= range.start && clipRange.end <= range.end {
                tracks[index].remove(clip.id)
            } else if clipRange.start < range.start && clipRange.end > range.end {
                var after = clip
                after.id = UUID()
                after.moveStart(to: range.end, isStill: isStill)
                tracks[index].update(clip.id) { $0.moveEnd(to: range.start) }
                tracks[index].insert(after)
            } else if clipRange.start < range.start {
                tracks[index].update(clip.id) { $0.moveEnd(to: range.start) }
            } else {
                tracks[index].update(clip.id) { $0.moveStart(to: range.end, isStill: isStill) }
            }
        }
    }

    /// Takes clips off the timeline, leaving gaps where they were.
    public mutating func removeClips(_ ids: Set<Clip.ID>) {
        for index in tracks.indices {
            for clip in tracks[index].clips where ids.contains(clip.id) {
                tracks[index].remove(clip.id)
            }
        }
    }

    /// Takes clips off the timeline and closes up the gaps they leave: the
    /// clips after each one on its track move back by its length. Other
    /// tracks stay as they are.
    public mutating func rippleDeleteClips(_ ids: Set<Clip.ID>) {
        for index in tracks.indices {
            let removed = tracks[index].clips.filter { ids.contains($0.id) }
            guard !removed.isEmpty else { continue }
            for clip in removed { tracks[index].remove(clip.id) }
            for clip in tracks[index].clips {
                let closed = removed.filter { $0.timelineRange.end <= clip.timelineStart }
                    .reduce(CMTime.zero) { $0 + $1.duration }
                tracks[index].update(clip.id) { $0.timelineStart = $0.timelineStart - closed }
            }
        }
    }

    /// Whether a clip's sound can be split off into a clip of its own: a
    /// video's clip on a video track, with sound, that's still attached.
    public func canDetachAudio(from id: Clip.ID) -> Bool {
        guard let (trackIndex, clip) = location(of: id), tracks[trackIndex].kind == .video, !clip.isAudioDetached,
              let item = mediaItem(id: clip.mediaID) else { return false }
        return item.kind == .video && item.metadata.hasAudio
    }

    /// Splits a video clip's sound off into an audio clip of its own, of the
    /// same stretch of the same media at the same time, so the two can be
    /// edited apart. The video clip plays only its picture from then on.
    ///
    /// The sound goes on the first audio track with room for it, or on a new
    /// one, and takes the clip's volume and audio effects with it; its video
    /// effects stay. Returns the audio clip's ID, or nil if the clip has no
    /// sound to detach.
    @discardableResult
    public mutating func detachAudio(from id: Clip.ID) -> Clip.ID? {
        guard canDetachAudio(from: id), let (trackIndex, clip) = location(of: id) else { return nil }
        let audio = Clip(
            mediaID: clip.mediaID, sourceRange: clip.sourceRange, timelineStart: clip.timelineStart,
            volume: clip.volume, effects: clip.effects.filter { !$0.kind.isVideo }
        )
        tracks[trackIndex].update(id) { clip in
            clip.isAudioDetached = true
            clip.volume = Animatable(1)
            clip.effects.removeAll { !$0.kind.isVideo }
        }
        let range = clip.timelineRange
        let free = tracks.indices.first { index in
            tracks[index].kind == .audio
                && !tracks[index].clips.contains { $0.timelineStart < range.end && $0.timelineRange.end > range.start }
        }
        let audioTrack = free ?? insertTrack(of: .audio)
        tracks[audioTrack].insert(audio)
        return audio.id
    }
}
