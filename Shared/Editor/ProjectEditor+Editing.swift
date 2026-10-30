import CoreMedia
import Foundation
import MontageEngine

/// The selection, and the edits that act on it or at the playhead, shared by
/// the timeline, its keyboard shortcuts, the toolbars and the menus.
extension ProjectEditor {
    // MARK: - Selection

    /// The selected clips that are still on the timeline. This is what the
    /// inspector and the edit commands act on.
    var selectedClipIDs: Set<Clip.ID> {
        let selected = timeline.selectedClipIDs
        guard !selected.isEmpty else { return [] }
        return Set(project.tracks.flatMap(\.clips).map(\.id).filter(selected.contains))
    }

    /// The selected clips, in track and then timeline order.
    var selectedClips: [Clip] {
        let selected = timeline.selectedClipIDs
        return project.tracks.flatMap(\.clips).filter { selected.contains($0.id) }
    }

    /// The one selected clip, for the inspector to show, or nil when there
    /// are none or several.
    var selectedClip: Clip? {
        let clips = selectedClips
        return clips.count == 1 ? clips[0] : nil
    }

    /// Selects a clip, alone or, `extending`, along with the rest, where
    /// selecting it again takes it out.
    func select(_ id: Clip.ID, extending: Bool = false) {
        if extending {
            if timeline.selectedClipIDs.contains(id) {
                timeline.selectedClipIDs.remove(id)
            } else {
                timeline.selectedClipIDs.insert(id)
            }
        } else {
            timeline.selectedClipIDs = [id]
        }
    }

    func selectAllClips() {
        timeline.selectedClipIDs = Set(project.tracks.flatMap(\.clips).map(\.id))
    }

    func deselectAll() {
        timeline.selectedClipIDs = []
        timeline.selectedTransitionID = nil
    }

    // MARK: - Splitting

    /// The start of the frame the playhead shows: where edits at the
    /// playhead go, so they stay on the frame grid while playing, when the
    /// player's time falls between frames.
    private var playheadFrame: CMTime {
        playback.frames.snapped(playback.currentTime)
    }

    /// The clips Split cuts: the selected clips under the playhead, or every
    /// clip under it if none of those is selected.
    private var clipsToSplit: Set<Clip.ID> {
        let time = playheadFrame
        let minimum = project.minimumClipDuration
        let under = project.tracks.flatMap(\.clips).filter {
            time >= $0.timelineStart + minimum && time <= $0.timelineRange.end - minimum
        }
        let selected = under.filter { timeline.selectedClipIDs.contains($0.id) }
        return Set((selected.isEmpty ? under : selected).map(\.id))
    }

    var canSplit: Bool { !clipsToSplit.isEmpty }

    /// Cuts the clips under the playhead in two there.
    func splitAtPlayhead() {
        let ids = clipsToSplit
        guard !ids.isEmpty else { return }
        let time = playheadFrame
        perform(String(localized: "Action.Split")) { $0.splitClips(ids, at: time) }
    }

    // MARK: - Deleting

    var canDelete: Bool { !selectedClipIDs.isEmpty || selectedTransition != nil }

    /// Takes the selected clips off the timeline; `ripple` closes up the
    /// gaps they leave. With no clips selected, takes off the selected
    /// transition.
    func deleteSelection(ripple: Bool = false) {
        let ids = selectedClipIDs
        guard !ids.isEmpty else {
            removeSelectedTransition()
            return
        }
        let name = String(localized: ripple ? "Action.RippleDelete" : "Action.Delete")
        perform(name) { project in
            if ripple { project.rippleDeleteClips(ids) } else { project.removeClips(ids) }
        }
        deselectAll()
    }

    // MARK: - Detaching audio

    var canDetachAudio: Bool {
        selectedClipIDs.contains { project.canDetachAudio(from: $0) }
    }

    /// Splits the sound off each selected video clip that has it, selecting
    /// the audio clips along with the video.
    func detachAudio() {
        let ids = selectedClipIDs.filter { project.canDetachAudio(from: $0) }
        guard !ids.isEmpty else { return }
        var detached: [Clip.ID] = []
        perform(String(localized: "Action.DetachAudio")) { project in
            detached = ids.compactMap { project.detachAudio(from: $0) }
        }
        timeline.selectedClipIDs.formUnion(detached)
    }

    // MARK: - Marking

    /// Marks the playhead's time.
    func addMarkerAtPlayhead() {
        let time = playheadFrame
        perform(String(localized: "Action.AddMarker")) { $0.addMarker(at: time) }
    }

    /// Marks the start of a range at the playhead, letting go of an end
    /// marked before it.
    func markIn() {
        let time = playheadFrame
        timeline.markedIn = time
        if let out = timeline.markedOut, out <= time { timeline.markedOut = nil }
    }

    /// Marks the end of a range at the playhead, letting go of a start
    /// marked after it.
    func markOut() {
        let time = playheadFrame
        timeline.markedOut = time
        if let markedIn = timeline.markedIn, markedIn >= time { timeline.markedIn = nil }
    }

    func clearMarkedRange() {
        timeline.markedIn = nil
        timeline.markedOut = nil
    }
}
