import CoreMedia
import Foundation
import MontageEngine

/// Puts the clips an importer finds onto tracks.
///
/// Other editors place clips in lanes, and some (Final Cut) have no tracks at
/// all, so clips are gathered by kind and lane first and made into tracks at
/// the end: one track for each lane, video lanes stacked bottom lane first
/// and audio lanes after them. Montage's tracks can't hold overlapping clips,
/// so where two overlap under a transition the cut goes in the overlap's
/// middle, and any other clip that overlaps is moved up onto a track of its
/// own, beside its lane's.
///
/// A transition added with a kind Montage plays becomes one of Montage's at
/// the cut it's over on a video lane: between clips that overlap under it,
/// over as much of it as they overlap, the media under the overlap being
/// the handles it shows, or between clips that meet under it, over the
/// whole of it. One that joins no two clips that way, such as one from a
/// clip into a gap, is cut and reported. A transition with no kind is cut,
/// and the importer reports it.
struct TimelineAssembler {
    private struct Lane: Hashable {
        var kind: Track.Kind
        var number: Int
    }

    /// A transition in the file.
    private struct Join {
        var range: CMTimeRange
        /// What it becomes, if it becomes one of Montage's.
        var kind: ClipTransition.Kind?
        /// What the report calls it, if it can't be made.
        var name: String
    }

    private var clips: [Lane: [Clip]] = [:]
    private var names: [Clip.ID: String] = [:]
    /// What the other editor called each lane's track.
    private var laneNames: [Lane: String] = [:]
    /// Where transitions were, by the lane they joined clips on.
    private var transitions: [Int: [Join]] = [:]

    mutating func add(_ clip: Clip, kind: Track.Kind, lane: Int, name: String?) {
        guard clip.duration > .zero else { return }
        clips[Lane(kind: kind, number: lane), default: []].append(clip)
        if let name { names[clip.id] = name }
    }

    /// Names the track a lane becomes. Clips moved off the lane onto tracks
    /// of their own leave the name with the lane's own track. Names that
    /// only number the track, such as "V1" or "Audio 2", are left out:
    /// Montage numbers tracks itself.
    mutating func nameLane(_ name: String?, kind: Track.Kind, lane: Int) {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              name.wholeMatch(of: /(?i)(v|a|video|audio)\s*\d+/) == nil else { return }
        laneNames[Lane(kind: kind, number: lane)] = name
    }

    /// Notes a transition joining two clips on a lane, where they're cut.
    mutating func addTransition(_ range: CMTimeRange, lane: Int) {
        transitions[lane, default: []].append(Join(range: range, kind: nil, name: ""))
    }

    /// Notes a transition joining two clips on a lane that becomes one of
    /// `kind`, or is cut and reported by its name if it can't.
    mutating func addTransition(_ range: CMTimeRange, lane: Int, as kind: ClipTransition.Kind, name: String) {
        transitions[lane, default: []].append(Join(range: range, kind: kind, name: name))
    }

    /// The tracks, video first, with what had to change to fit them.
    func tracks(report: inout ImportReport) -> [Track] {
        timeline(report: &report).tracks
    }

    /// The tracks, video first, and the transitions at cuts between their
    /// clips, with what had to change to fit them.
    func timeline(report: inout ImportReport) -> (tracks: [Track], transitions: [ClipTransition]) {
        let order = clips.keys.sorted { a, b in
            if a.kind != b.kind { return a.kind == .video }
            // Audio reads down from the lane nearest the picture.
            return a.kind == .video ? a.number < b.number : Self.audioOrder(a.number) < Self.audioOrder(b.number)
        }
        var tracks: [Track] = []
        var made: [ClipTransition] = []
        // The transitions made, by lane and their place in it.
        var used: Set<[Int]> = []
        for lane in order {
            let laneClips = clips[lane, default: []].sorted { $0.timelineStart < $1.timelineStart }
            var rows: [[Clip]] = [[]]
            let joins = transitions[lane.number] ?? []
            for clip in laneClips {
                if let (transition, index) = place(clip, in: &rows, joins: joins, makesTransitions: lane.kind == .video,
                                                   report: &report) {
                    made.append(transition)
                    used.insert([lane.number, index])
                }
            }
            tracks += rows.enumerated().filter { !$0.element.isEmpty }.map { index, row in
                Track(kind: lane.kind, name: index == 0 ? laneNames[lane] : nil, clips: row)
            }
        }
        for (lane, joins) in transitions.sorted(by: { $0.key < $1.key }) {
            for (index, join) in joins.enumerated() where join.kind != nil && !used.contains([lane, index]) {
                report.add(.transition(name: join.name), time: join.range.start)
            }
        }
        return (tracks, made)
    }

    private static func audioOrder(_ lane: Int) -> Int {
        lane <= 0 ? -lane : 1000 + lane
    }

    /// Puts a clip on the first row it fits on. Returns the transition into
    /// it from the clip before, and which of `joins` it's made from, if it's
    /// joined to that clip by one Montage plays.
    private func place(
        _ clip: Clip, in rows: inout [[Clip]], joins: [Join], makesTransitions: Bool, report: inout ImportReport
    ) -> (ClipTransition, Int)? {
        if let previous = rows[0].last {
            let overlap = previous.timelineRange.intersection(clip.timelineRange)
            // Overlapping the last clip of the lane's own track under a
            // transition: cut halfway through the overlap.
            if overlap.duration > .zero, let index = joins.firstIndex(where: { $0.range.intersection(overlap).duration > .zero }) {
                let cut = overlap.start + CMTimeMultiplyByRatio(overlap.duration, multiplier: 1, divisor: 2)
                rows[0].removeLast()
                let before = previous.trimmed(to: CMTimeRange(start: previous.timelineStart, end: cut))
                if let before { rows[0].append(before) }
                let after = clip.trimmed(to: CMTimeRange(start: cut, end: clip.timelineRange.end))
                if let after { rows[0].append(after) }
                guard makesTransitions, let kind = joins[index].kind, let before, let after else { return nil }
                let range = joins[index].range.intersection(overlap)
                let transition = ClipTransition(kind: kind, from: before.id, to: after.id, beforeCut: max(.zero, cut - range.start),
                                            afterCut: max(.zero, range.end - cut))
                return (transition, index)
            }
            // Meeting it under one.
            let cut = clip.timelineStart
            if makesTransitions, previous.timelineRange.end == cut, let index = joins.firstIndex(where: {
                $0.kind != nil && $0.range.duration > .zero && $0.range.start <= cut && cut <= $0.range.end
            }), let kind = joins[index].kind {
                rows[0].append(clip)
                let range = joins[index].range
                return (ClipTransition(kind: kind, from: previous.id, to: clip.id, beforeCut: cut - range.start, afterCut: range.end - cut), index)
            }
        }
        for index in rows.indices where rows[index].last.map({ $0.timelineRange.end <= clip.timelineStart }) ?? true {
            if index > 0 { report.add(.movedToNewTrack, clipName: names[clip.id], time: clip.timelineStart) }
            rows[index].append(clip)
            return nil
        }
        report.add(.movedToNewTrack, clipName: names[clip.id], time: clip.timelineStart)
        rows.append([clip])
        return nil
    }
}

extension Clip {
    /// The part of the clip within a stretch of the timeline, or nil if it
    /// has none there. Keyframes keep their place on the timeline.
    func trimmed(to range: CMTimeRange) -> Clip? {
        let kept = timelineRange.intersection(range)
        guard kept.duration > .zero else { return nil }
        let cut = kept.start - timelineStart
        var clip = self
        clip.timelineStart = kept.start
        clip.sourceRange = CMTimeRange(start: sourceRange.start + speed.mediaDuration(ofTimeline: cut),
                                       duration: speed.mediaDuration(ofTimeline: kept.duration))
        if cut != .zero { clip.shiftKeyframes(by: .zero - cut) }
        return clip
    }

    /// Moves every keyframe along the clip, as when its start is trimmed.
    mutating func shiftKeyframes(by offset: CMTime) {
        volume = volume.shifted(by: offset)
        opacity = opacity.shifted(by: offset)
        transform.position = transform.position.shifted(by: offset)
        transform.scale = transform.scale.shifted(by: offset)
        transform.rotation = transform.rotation.shifted(by: offset)
        for index in effects.indices {
            switch effects[index].kind {
            case .colorCorrection(var parameters):
                parameters.exposure = parameters.exposure.shifted(by: offset)
                parameters.contrast = parameters.contrast.shifted(by: offset)
                parameters.saturation = parameters.saturation.shifted(by: offset)
                parameters.temperature = parameters.temperature.shifted(by: offset)
                parameters.tint = parameters.tint.shifted(by: offset)
                effects[index].kind = .colorCorrection(parameters)
            case .mosaic(var parameters):
                parameters.scale = parameters.scale.shifted(by: offset)
                effects[index].kind = .mosaic(parameters)
            case .gain(var parameters):
                parameters.decibels = parameters.decibels.shifted(by: offset)
                effects[index].kind = .gain(parameters)
            case .pan(var parameters):
                parameters.position = parameters.position.shifted(by: offset)
                effects[index].kind = .pan(parameters)
            // Imports make no keyframes on the others.
            default:
                break
            }
        }
    }
}

extension Animatable {
    func shifted(by offset: CMTime) -> Animatable {
        guard isAnimated, offset != .zero else { return self }
        return Animatable(value, keyframes: keyframes.map { keyframe in
            var keyframe = keyframe
            keyframe.time = keyframe.time + offset
            return keyframe
        })
    }
}
