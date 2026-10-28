import CoreMedia
import Foundation
import MontageEngine

/// Adding transitions at cuts, and changing or taking off the one selected.
extension ProjectEditor {
    /// How long a transition is when it's added.
    static let defaultTransitionDuration = 1.0

    /// How near the playhead a cut has to be for a transition to go on it
    /// when no clip is selected.
    private static let cutTolerance = CMTime(value: 1, timescale: 1)

    // MARK: - Selection

    /// The selected transition, where it plays, if it still does.
    var selectedTransition: PlacedTransition? {
        guard let id = timeline.selectedTransitionID else { return nil }
        return project.placedTransitions().first { $0.transition.id == id }?.transition
    }

    /// Selects a transition alone, letting go of the selected clips.
    func selectTransition(_ id: ClipTransition.ID) {
        timeline.selectedClipIDs = []
        timeline.selectedTransitionID = id
    }

    // MARK: - Adding

    /// The cuts a transition goes on: those at either end of the selected
    /// clips on video tracks, or, with none selected, the cut on a video
    /// track nearest the playhead, if one is near it.
    private var cutsForTransition: [(outgoing: Clip.ID, incoming: Clip.ID)] {
        let tracks = project.tracks.indices.filter { project.tracks[$0].kind == .video }
        let selected = selectedClipIDs
        if !selected.isEmpty {
            return tracks.flatMap { index in
                let clips = project.tracks[index].clips
                return zip(clips, clips.dropFirst())
                    .filter { $0.timelineRange.end == $1.timelineStart && (selected.contains($0.id) || selected.contains($1.id)) }
                    .map { ($0.id, $1.id) }
            }
        }
        let time = playback.frames.snapped(playback.currentTime)
        let nearest = tracks.compactMap { project.cut(near: time, onTrackAt: $0, within: Self.cutTolerance) }
            .min { abs(($0.incoming.timelineStart - time).seconds) < abs(($1.incoming.timelineStart - time).seconds) }
        return nearest.map { [($0.outgoing.id, $0.incoming.id)] } ?? []
    }

    var canAddTransition: Bool { !cutsForTransition.isEmpty }

    /// Puts a cross dissolve on each cut `cutsForTransition` finds, a
    /// second long, in place of any there. A lone one is selected.
    func addCrossDissolve() {
        let cuts = cutsForTransition
        guard !cuts.isEmpty else { return }
        let duration = playback.frames.rounded(seconds: Self.defaultTransitionDuration)
        var added: [ClipTransition.ID] = []
        perform(String(localized: "Action.AddCrossDissolve")) { project in
            added = cuts.compactMap { project.addTransition(.crossDissolve, from: $0.outgoing, to: $0.incoming, duration: duration) }
        }
        if added.count == 1, selectedClipIDs.isEmpty { selectTransition(added[0]) }
    }

    // MARK: - Changing

    /// Makes the selected transition a length, to the nearest frame.
    func setSelectedTransitionDuration(seconds: Double) {
        guard let id = timeline.selectedTransitionID else { return }
        let duration = max(playback.frames.rounded(seconds: seconds), playback.frames.frameDuration)
        coalescingChanges("Transition.Duration") {
            perform(String(localized: "Action.ChangeTransition")) { $0.setDuration(ofTransition: id, to: duration) }
        }
    }

    func removeSelectedTransition() {
        guard let id = selectedTransition?.id else { return }
        perform(String(localized: "Action.RemoveTransition")) { $0.removeTransitions([id]) }
        timeline.selectedTransitionID = nil
    }
}
