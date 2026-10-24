import CoreMedia
import Foundation

/// Which end of a clip an edit takes hold of.
public enum ClipEdge: Sendable {
    case start, end
}

/// How trimming one clip treats the clips after it on its track.
public enum TrimStyle: Sendable {
    /// Only the clip changes: it can't grow over its neighbours, and
    /// shortening it leaves a gap.
    case trim
    /// The clips after it on the track move with the edge, so no gap opens
    /// and nothing is covered: the track gets longer or shorter instead.
    case ripple
    /// The cut between the clip and the neighbour touching it moves, one
    /// growing as the other shrinks, so nothing else on the track moves.
    /// Without a neighbour touching that edge, it trims.
    case roll
}

// MARK: - Clips

extension Clip {
    /// Moves every keyframe of the clip's own parameters along by `offset`,
    /// so after its start is trimmed by the opposite amount they stay on the
    /// same frames of the media.
    ///
    /// TODO: effects' keyframes aren't moved yet; each effect's parameters
    /// will need the same once effects can be keyframed in the inspector.
    mutating func shiftKeyframes(by offset: CMTime) {
        guard offset != .zero else { return }
        volume = volume.shifted(by: offset)
        opacity = opacity.shifted(by: offset)
        transform.position = transform.position.shifted(by: offset)
        transform.scale = transform.scale.shifted(by: offset)
        transform.rotation = transform.rotation.shifted(by: offset)
        content = content.shifted(by: offset)
        // The scale and position put back when Ken Burns comes off are on
        // the clip's time too, so they move with it.
        if var kenBurns {
            kenBurns.previousScale = kenBurns.previousScale.shifted(by: offset)
            kenBurns.previousPosition = kenBurns.previousPosition.shifted(by: offset)
            self.kenBurns = kenBurns
        }
    }

    /// Moves the clip's start to a time on the timeline, keeping its end,
    /// taking more or less of its media: the media under every frame left,
    /// and its keyframes, stay where they were. The caller keeps it within
    /// its media and at least a frame long.
    mutating func moveStart(to time: CMTime, isStill: Bool) {
        let delta = time - timelineStart
        let duration = sourceRange.duration - delta
        // A still has no time of its own to take from, so it only gets longer.
        let sourceStart = isStill ? sourceRange.start : sourceRange.start + delta
        sourceRange = CMTimeRange(start: sourceStart, duration: duration)
        timelineStart = time
        // A still's keyframes stay put too, or the part of it after a split
        // would start its animation over.
        shiftKeyframes(by: .zero - delta)
    }

    /// Moves the clip's end to a time on the timeline, keeping its start.
    mutating func moveEnd(to time: CMTime) {
        sourceRange = CMTimeRange(start: sourceRange.start, duration: time - timelineStart)
    }
}

extension Animatable {
    /// The same parameter with every keyframe moved along by `offset`.
    func shifted(by offset: CMTime) -> Animatable {
        guard isAnimated, offset != .zero else { return self }
        var keyframes = self.keyframes
        for index in keyframes.indices { keyframes[index].time = keyframes[index].time + offset }
        return Animatable(value, keyframes: keyframes)
    }
}

// MARK: - Trimming and splitting

extension Project {
    /// The shortest a clip can be trimmed to: one frame.
    public var minimumClipDuration: CMTime { settings.frameDuration }

    /// Where a clip is: the index of its track, and the clip.
    public func location(of id: Clip.ID) -> (trackIndex: Int, clip: Clip)? {
        for (index, track) in tracks.enumerated() {
            if let clip = track.clip(id: id) { return (index, clip) }
        }
        return nil
    }

    /// Whether a clip has no time of its own (a still image, text or a
    /// shape), so it can be made as long as it's wanted.
    func isStill(_ clip: Clip) -> Bool {
        !clip.content.hasSourceTime || mediaItem(id: clip.mediaID)?.kind == .image
    }

    /// How long a clip's media runs, which it can't be trimmed past. Nil for
    /// a still, or media that isn't in the project, which don't hold it back.
    func mediaDuration(of clip: Clip) -> CMTime? {
        guard !isStill(clip), let item = mediaItem(id: clip.mediaID) else { return nil }
        let duration = item.metadata.duration
        return duration.isNumeric && duration > .zero ? duration : nil
    }

    /// The latest a clip's end can be moved to before it runs out of media.
    private func latestEnd(of clip: Clip) -> CMTime? {
        mediaDuration(of: clip).map { clip.timelineStart + ($0 - clip.sourceRange.start) }
    }

    /// The earliest a clip's start can be moved to before it runs out of
    /// media, or the timeline's start.
    private func earliestStart(of clip: Clip) -> CMTime {
        guard mediaDuration(of: clip) != nil else { return .zero }
        return max(.zero, clip.timelineStart - clip.sourceRange.start)
    }

    /// The clips either side of one on its track.
    private func neighbours(of clip: Clip, onTrackAt index: Int) -> (before: Clip?, after: Clip?) {
        let clips = tracks[index].clips
        let before = clips.last { $0.id != clip.id && $0.timelineRange.end <= clip.timelineStart }
        let after = clips.first { $0.id != clip.id && $0.timelineStart >= clip.timelineRange.end }
        return (before, after)
    }

    /// Moves one edge of a clip as near to a time on the timeline as it can
    /// go: not past its media, not shorter than a frame, and, depending on
    /// the style, not over its neighbours. Returns where the edge ended up,
    /// or nil if the clip isn't in the project.
    ///
    /// Rippling the start keeps the clip where it starts and moves what
    /// comes after it instead, so the returned time is the clip's new end
    /// moved back by its old length: where the start would have gone.
    @discardableResult
    public mutating func trimClip(_ id: Clip.ID, edge: ClipEdge, to time: CMTime, style: TrimStyle = .trim) -> CMTime? {
        guard let (trackIndex, clip) = location(of: id) else { return nil }
        if style == .roll, let rolled = roll(clip, onTrackAt: trackIndex, edge: edge, to: time) { return rolled }
        let minimum = minimumClipDuration
        let (before, after) = neighbours(of: clip, onTrackAt: trackIndex)
        let isStill = isStill(clip)

        switch (edge, style) {
        case (.end, .ripple):
            var end = max(time, clip.timelineStart + minimum)
            if let latest = latestEnd(of: clip) { end = min(end, latest) }
            let delta = end - clip.timelineRange.end
            shiftClips(onTrackAt: trackIndex, from: clip.timelineRange.end, by: delta, except: [id])
            tracks[trackIndex].update(id) { $0.moveEnd(to: end) }
            return end

        case (.end, _):
            var end = max(time, clip.timelineStart + minimum)
            if let latest = latestEnd(of: clip) { end = min(end, latest) }
            if let after { end = min(end, after.timelineStart) }
            end = max(end, clip.timelineStart + minimum)
            tracks[trackIndex].update(id) { $0.moveEnd(to: end) }
            return end

        case (.start, .ripple):
            // The clip stays where it starts; taking `delta` more or less of
            // its media off the front moves what follows it the other way.
            var delta = min(time - clip.timelineStart, clip.duration - minimum)
            if !isStill { delta = max(delta, .zero - clip.sourceRange.start) }
            let oldEnd = clip.timelineRange.end
            tracks[trackIndex].update(id) { clip in
                clip.moveStart(to: clip.timelineStart + delta, isStill: isStill)
                clip.timelineStart = clip.timelineStart - delta
            }
            shiftClips(onTrackAt: trackIndex, from: oldEnd, by: .zero - delta, except: [id])
            return clip.timelineStart + delta

        case (.start, _):
            var start = min(time, clip.timelineRange.end - minimum)
            start = max(start, earliestStart(of: clip))
            if let before { start = max(start, before.timelineRange.end) }
            start = min(start, clip.timelineRange.end - minimum)
            tracks[trackIndex].update(id) { $0.moveStart(to: start, isStill: isStill) }
            return start
        }
    }

    /// Moves the cut at one edge of a clip, if a clip touches it there: the
    /// clip and its neighbour change length together. Nil if nothing touches
    /// that edge, to be trimmed instead.
    private mutating func roll(_ clip: Clip, onTrackAt trackIndex: Int, edge: ClipEdge, to time: CMTime) -> CMTime? {
        let (before, after) = neighbours(of: clip, onTrackAt: trackIndex)
        let left: Clip, right: Clip
        switch edge {
        case .start:
            guard let before, before.timelineRange.end == clip.timelineStart else { return nil }
            (left, right) = (before, clip)
        case .end:
            guard let after, after.timelineStart == clip.timelineRange.end else { return nil }
            (left, right) = (clip, after)
        }
        let minimum = minimumClipDuration
        var cut = time
        cut = max(cut, left.timelineStart + minimum, earliestStart(of: right))
        if let latest = latestEnd(of: left) { cut = min(cut, latest) }
        cut = min(cut, right.timelineRange.end - minimum)
        // Clips too short to roll either way leave the cut where it is.
        guard cut >= left.timelineStart + minimum else { return left.timelineRange.end }
        let isStill = isStill(right)
        tracks[trackIndex].update(left.id) { $0.moveEnd(to: cut) }
        tracks[trackIndex].update(right.id) { $0.moveStart(to: cut, isStill: isStill) }
        return cut
    }

    /// Moves every clip on a track that starts at or after a time along by
    /// an offset.
    mutating func shiftClips(onTrackAt index: Int, from time: CMTime, by offset: CMTime, except ids: Set<Clip.ID> = []) {
        guard offset != .zero else { return }
        for clip in tracks[index].clips where clip.timelineStart >= time && !ids.contains(clip.id) {
            tracks[index].update(clip.id) { $0.timelineStart = $0.timelineStart + offset }
        }
    }

    /// Cuts a clip in two at a time on the timeline. The part after the cut
    /// becomes a new clip, with the same media, settings and effects, and
    /// its keyframes moved so they stay where they were. Returns the new
    /// clip's ID, or nil if the time isn't inside the clip, at least a frame
    /// from either end.
    @discardableResult
    public mutating func splitClip(_ id: Clip.ID, at time: CMTime) -> Clip.ID? {
        guard let (trackIndex, clip) = location(of: id) else { return nil }
        let minimum = minimumClipDuration
        guard time >= clip.timelineStart + minimum, time <= clip.timelineRange.end - minimum else { return nil }
        var after = clip
        after.id = UUID()
        after.moveStart(to: time, isStill: isStill(clip))
        tracks[trackIndex].update(id) { $0.moveEnd(to: time) }
        tracks[trackIndex].insert(after)
        return after.id
    }

    /// Cuts the given clips, or every clip if there are none given, wherever
    /// they're under a time. Returns the new clips' IDs.
    @discardableResult
    public mutating func splitClips(_ ids: Set<Clip.ID>? = nil, at time: CMTime) -> [Clip.ID] {
        let clips = tracks.flatMap(\.clips).filter { ids?.contains($0.id) ?? true }
        return clips.compactMap { splitClip($0.id, at: time) }
    }
}
