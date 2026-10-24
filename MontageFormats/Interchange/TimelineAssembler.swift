import CoreMedia
import Foundation
import MontageEngine

/// Puts the clips an importer finds onto tracks.
///
/// Other editors place clips in lanes, and some (Final Cut) have no tracks at
/// all, so clips are gathered by kind and lane first and made into tracks at
/// the end: one track for each lane, video lanes stacked bottom lane first
/// and audio lanes after them. Montage's tracks can't hold overlapping clips,
/// so where two overlap under a transition the cut goes in the transition's
/// middle, and any other clip that overlaps is moved up onto a track of its
/// own, beside its lane's.
struct TimelineAssembler {
    private struct Lane: Hashable {
        var kind: Track.Kind
        var number: Int
    }

    private var clips: [Lane: [Clip]] = [:]
    private var names: [Clip.ID: String] = [:]
    /// Where transitions were, by the lane they joined clips on.
    private var transitions: [Int: [CMTimeRange]] = [:]

    mutating func add(_ clip: Clip, kind: Track.Kind, lane: Int, name: String?) {
        guard clip.duration > .zero else { return }
        clips[Lane(kind: kind, number: lane), default: []].append(clip)
        if let name { names[clip.id] = name }
    }

    mutating func addTransition(_ range: CMTimeRange, lane: Int) {
        transitions[lane, default: []].append(range)
    }

    /// The tracks, video first, with what had to change to fit them.
    func tracks(report: inout ImportReport) -> [Track] {
        let order = clips.keys.sorted { a, b in
            if a.kind != b.kind { return a.kind == .video }
            // Audio reads down from the lane nearest the picture.
            return a.kind == .video ? a.number < b.number : Self.audioOrder(a.number) < Self.audioOrder(b.number)
        }
        var tracks: [Track] = []
        for lane in order {
            let laneClips = clips[lane, default: []].sorted { $0.timelineStart < $1.timelineStart }
            var rows: [[Clip]] = [[]]
            for clip in laneClips {
                place(clip, in: &rows, transitions: transitions[lane.number] ?? [], report: &report)
            }
            tracks += rows.filter { !$0.isEmpty }.map { Track(kind: lane.kind, clips: $0) }
        }
        return tracks
    }

    private static func audioOrder(_ lane: Int) -> Int {
        lane <= 0 ? -lane : 1000 + lane
    }

    private func place(_ clip: Clip, in rows: inout [[Clip]], transitions: [CMTimeRange], report: inout ImportReport) {
        // Overlapping the last clip of the lane's own track under a
        // transition: cut halfway through the overlap.
        if let previous = rows[0].last {
            let overlap = previous.timelineRange.intersection(clip.timelineRange)
            if overlap.duration > .zero, transitions.contains(where: { $0.intersection(overlap).duration > .zero }) {
                let cut = overlap.start + CMTimeMultiplyByRatio(overlap.duration, multiplier: 1, divisor: 2)
                rows[0].removeLast()
                if let before = previous.trimmed(to: CMTimeRange(start: previous.timelineStart, end: cut)) {
                    rows[0].append(before)
                }
                if let after = clip.trimmed(to: CMTimeRange(start: cut, end: clip.timelineRange.end)) {
                    rows[0].append(after)
                }
                return
            }
        }
        for index in rows.indices where rows[index].last.map({ $0.timelineRange.end <= clip.timelineStart }) ?? true {
            if index > 0 { report.add(.movedToNewTrack, clipName: names[clip.id], time: clip.timelineStart) }
            rows[index].append(clip)
            return
        }
        report.add(.movedToNewTrack, clipName: names[clip.id], time: clip.timelineStart)
        rows.append([clip])
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
        clip.sourceRange = CMTimeRange(start: sourceRange.start + cut, duration: kept.duration)
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
