import CoreMedia
import Foundation
import MontageEngine

/// Changes to the effects on the selected clip, each one undo step.
extension ProjectEditor {
    /// The clip the inspector shows, with the track it's on: the selected
    /// clip, while just one is selected and it's still in the project.
    var inspectedClip: (track: Track, clip: Clip)? {
        guard selectedClipIDs.count == 1, let id = selectedClipIDs.first else { return nil }
        return project.clip(id: id)
    }

    /// Where the playhead is in a clip, as the time its keyframes are
    /// measured in, kept within the clip.
    func clipTime(in clip: Clip) -> CMTime {
        let time = clip.localTime(playback.currentTime)
        return min(max(time, .zero), clip.duration)
    }

    /// Whether the playhead is on a clip, so a keyframe set there would be
    /// where it's seen.
    func isPlayheadOn(_ clip: Clip) -> Bool {
        clip.timelineRange.containsTime(playback.currentTime)
    }

    func addEffect(_ kind: Effect.Kind, toClip clipID: Clip.ID) {
        perform(String(localized: "Inspector.Action.AddEffect")) { $0.addEffect(Effect(kind), toClip: clipID) }
    }

    func removeEffect(_ effectID: Effect.ID, fromClip clipID: Clip.ID) {
        perform(String(localized: "Inspector.Action.RemoveEffect")) { $0.removeEffect(effectID, fromClip: clipID) }
    }

    func moveEffect(_ effectID: Effect.ID, ofClip clipID: Clip.ID, by offset: Int) {
        perform(String(localized: "Inspector.Action.MoveEffect")) { $0.moveEffect(effectID, ofClip: clipID, by: offset) }
    }

    /// Changes an effect: at once, as an undo step of its own, or as part of
    /// a drag that `endEffectChange` finishes.
    func changeEffect(
        _ effectID: Effect.ID, ofClip clipID: Clip.ID, continuously: Bool = false, _ change: (inout Effect) -> Void
    ) {
        let actionName = String(localized: "Inspector.Action.ChangeEffect")
        if continuously {
            // Not joining another gesture under way, which it'd start again
            // from before.
            if gestureActionName != actionName { beginGesture(actionName) }
            updateGesture { $0.updateEffect(effectID, ofClip: clipID, change) }
        } else {
            perform(actionName) { $0.updateEffect(effectID, ofClip: clipID, change) }
        }
    }

    func endEffectChange() {
        endGesture()
    }
}
