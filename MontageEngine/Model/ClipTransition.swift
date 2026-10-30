import CoreMedia
import Foundation

/// A transition at a cut: where one clip ends and the next on the same track
/// starts right after it, the picture goes from one to the other over a
/// stretch around the cut instead of all at once.
///
/// The clips stay where they are, cut against each other. Before the cut,
/// the incoming clip shows the media from before its start, and after it, the
/// outgoing clip the media from after its end: their handles. Where a clip's
/// media runs out, its first or last frame is held for the rest.
///
/// It's kept by the project, naming the two clips, and plays wherever they
/// are as long as they still meet on a track, so it goes with them when
/// they're moved together. One whose clips no longer meet does nothing, and
/// `removeStaleTransitions()` takes it off.
///
/// This is the shape transitions take in other editors' files too: an
/// overlap of `beforeCut` and `afterCut` about the cut (OpenTimelineIO's
/// in and out offsets, AAF's length and cut point, Final Cut Pro 7's
/// alignment), so importers make one wherever a file has a transition
/// Montage can play.
public struct ClipTransition: Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The outgoing picture fades out as the incoming one fades in.
        case crossDissolve
    }

    public var id: UUID
    public var kind: Kind
    /// The clip the transition goes from, which ends at the cut.
    public var outgoingClipID: Clip.ID
    /// The clip it goes to, which starts at the cut.
    public var incomingClipID: Clip.ID
    /// How much of the transition plays before the cut.
    public var beforeCut: CMTime
    /// How much plays after it.
    public var afterCut: CMTime

    public init(
        id: UUID = UUID(), kind: Kind = .crossDissolve, from outgoingClipID: Clip.ID, to incomingClipID: Clip.ID,
        beforeCut: CMTime, afterCut: CMTime
    ) {
        self.id = id
        self.kind = kind
        self.outgoingClipID = outgoingClipID
        self.incomingClipID = incomingClipID
        self.beforeCut = beforeCut
        self.afterCut = afterCut
    }

    /// A transition of a length centred on the cut, as most editors make one.
    public init(id: UUID = UUID(), kind: Kind = .crossDissolve, from outgoingClipID: Clip.ID, to incomingClipID: Clip.ID, duration: CMTime) {
        let half = CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)
        self.init(id: id, kind: kind, from: outgoingClipID, to: incomingClipID, beforeCut: half, afterCut: duration - half)
    }

    public var duration: CMTime { beforeCut + afterCut }
}

extension ClipTransition: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, kind, outgoingClipID, incomingClipID, beforeCut, afterCut
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        // A kind from a later build plays as a dissolve.
        kind = (try? container.decode(Kind.self, forKey: .kind)) ?? .crossDissolve
        outgoingClipID = try container.decode(Clip.ID.self, forKey: .outgoingClipID)
        incomingClipID = try container.decode(Clip.ID.self, forKey: .incomingClipID)
        beforeCut = try container.decode(CMTime.self, forKey: .beforeCut)
        afterCut = try container.decode(CMTime.self, forKey: .afterCut)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(outgoingClipID, forKey: .outgoingClipID)
        try container.encode(incomingClipID, forKey: .incomingClipID)
        try container.encode(beforeCut, forKey: .beforeCut)
        try container.encode(afterCut, forKey: .afterCut)
    }
}

/// A transition where it plays: at the cut between its clips, kept to what
/// they leave room for.
public struct PlacedTransition: Equatable, Sendable {
    public var transition: ClipTransition
    public var outgoing: Clip
    public var incoming: Clip
    /// How much plays before the cut: no more than the outgoing clip has
    /// after the transition into it, if there is one.
    public var beforeCut: CMTime
    /// How much plays after it: no more than the incoming clip is long.
    public var afterCut: CMTime

    public var id: ClipTransition.ID { transition.id }
    public var kind: ClipTransition.Kind { transition.kind }

    /// Where the outgoing clip ends and the incoming one starts.
    public var cut: CMTime { incoming.timelineStart }

    /// Where it plays on the timeline.
    public var timelineRange: CMTimeRange {
        CMTimeRange(start: cut - beforeCut, end: cut + afterCut)
    }

    /// How far through it a time is, from 0 at its start to 1 at its end.
    public func progress(at time: CMTime) -> Double {
        let range = timelineRange
        guard range.duration > .zero else { return time < cut ? 0 : 1 }
        return min(max((time - range.start).seconds / range.duration.seconds, 0), 1)
    }
}

extension Project {
    /// The transition with an ID, if the project has it.
    public func transition(id: ClipTransition.ID) -> ClipTransition? {
        transitions.first { $0.id == id }
    }

    /// The transitions that play on a track, in timeline order: those whose
    /// clips meet on it, each kept to the clips' lengths, so that none runs
    /// into the next. Where two are at the same cut, the first wins.
    public func placedTransitions(on track: Track) -> [PlacedTransition] {
        guard !transitions.isEmpty, track.clips.count > 1 else { return [] }
        // Each clip's next on the track, if it starts right where it ends.
        var next: [Clip.ID: Clip] = [:]
        var byID: [Clip.ID: Clip] = [:]
        for (clip, following) in zip(track.clips, track.clips.dropFirst()) where clip.timelineRange.end == following.timelineStart {
            next[clip.id] = following
        }
        for clip in track.clips { byID[clip.id] = clip }

        var atCut: [Clip.ID: ClipTransition] = [:]
        for transition in transitions where atCut[transition.outgoingClipID] == nil {
            guard next[transition.outgoingClipID]?.id == transition.incomingClipID else { continue }
            atCut[transition.outgoingClipID] = transition
        }
        var placed: [PlacedTransition] = []
        // How much of each clip the transition into it takes.
        var taken: [Clip.ID: CMTime] = [:]
        for clip in track.clips {
            guard let transition = atCut[clip.id], let incoming = next[clip.id] else { continue }
            let room = clip.duration - (taken[clip.id] ?? .zero)
            let before = max(.zero, min(transition.beforeCut, room))
            let after = max(.zero, min(transition.afterCut, incoming.duration))
            guard before + after > .zero else { continue }
            taken[incoming.id] = after
            placed.append(PlacedTransition(transition: transition, outgoing: clip, incoming: incoming, beforeCut: before, afterCut: after))
        }
        return placed
    }

    /// Every transition that plays, by the index of its track.
    public func placedTransitions() -> [(trackIndex: Int, transition: PlacedTransition)] {
        tracks.indices.flatMap { index in placedTransitions(on: tracks[index]).map { (index, $0) } }
    }

    /// The transition at the cut between two clips, if there's one.
    public func transition(from outgoing: Clip.ID, to incoming: Clip.ID) -> ClipTransition? {
        transitions.first { $0.outgoingClipID == outgoing && $0.incomingClipID == incoming }
    }

    /// The cut nearest a time on a track, if one is within `tolerance` of
    /// it: a clip and the one that starts where it ends.
    public func cut(near time: CMTime, onTrackAt index: Int, within tolerance: CMTime) -> (outgoing: Clip, incoming: Clip)? {
        guard tracks.indices.contains(index) else { return nil }
        let clips = tracks[index].clips
        return zip(clips, clips.dropFirst())
            .filter { $0.timelineRange.end == $1.timelineStart && abs(($1.timelineStart - time).seconds) <= tolerance.seconds }
            .min { abs(($0.1.timelineStart - time).seconds) < abs(($1.1.timelineStart - time).seconds) }
    }

    /// Puts a transition of a length at the cut between two clips, centred
    /// on it, in place of any already there. Nil if the clips don't meet on
    /// a track.
    @discardableResult
    public mutating func addTransition(
        _ kind: ClipTransition.Kind = .crossDissolve, from outgoing: Clip.ID, to incoming: Clip.ID, duration: CMTime
    ) -> ClipTransition.ID? {
        guard duration > .zero, let (trackIndex, clip) = location(of: outgoing),
              let after = tracks[trackIndex].clip(id: incoming), clip.timelineRange.end == after.timelineStart else { return nil }
        transitions.removeAll { $0.outgoingClipID == outgoing || $0.incomingClipID == incoming }
        let transition = ClipTransition(kind: kind, from: outgoing, to: incoming, duration: duration)
        transitions.append(transition)
        return transition.id
    }

    public mutating func removeTransitions(_ ids: Set<ClipTransition.ID>) {
        transitions.removeAll { ids.contains($0.id) }
    }

    /// Makes a transition longer or shorter, keeping the cut where it was
    /// in it, in proportion.
    public mutating func setDuration(ofTransition id: ClipTransition.ID, to duration: CMTime) {
        guard duration > .zero, let index = transitions.firstIndex(where: { $0.id == id }) else { return }
        let old = transitions[index]
        var before: CMTime
        if old.beforeCut == old.afterCut || old.duration <= .zero {
            before = CMTimeMultiplyByRatio(duration, multiplier: 1, divisor: 2)
        } else {
            let share = old.beforeCut.seconds / old.duration.seconds
            before = CMTime(seconds: duration.seconds * share, preferredTimescale: max(duration.timescale, 600))
        }
        before = min(max(before, .zero), duration)
        transitions[index].beforeCut = before
        transitions[index].afterCut = duration - before
    }

    /// Takes off the transitions whose clips are gone or no longer meet on
    /// a track, as after the clips are moved apart or deleted.
    public mutating func removeStaleTransitions() {
        guard !transitions.isEmpty else { return }
        let project = self
        transitions.removeAll { transition in
            guard let (trackIndex, outgoing) = project.location(of: transition.outgoingClipID),
                  let incoming = project.tracks[trackIndex].clip(id: transition.incomingClipID) else { return true }
            return outgoing.timelineRange.end != incoming.timelineStart
        }
    }

    /// Hands the transition out of a clip on to another clip, as when the
    /// clip is split and the part after the cut, a new clip, now ends where
    /// it did.
    mutating func moveOutgoingTransition(from id: Clip.ID, to newID: Clip.ID) {
        for index in transitions.indices where transitions[index].outgoingClipID == id {
            transitions[index].outgoingClipID = newID
        }
    }
}
