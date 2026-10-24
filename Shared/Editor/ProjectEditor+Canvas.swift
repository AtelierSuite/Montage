import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine

/// The layers in the preview, for picking one by tapping it and moving it
/// about with handles, and the clip parameter edits those and the inspector
/// make.
extension ProjectEditor {
    /// The clips the composition couldn't show, which the preview has
    /// nothing of to pick.
    var clipsLeftOutOfPicture: Set<Clip.ID> {
        Set(playback.composition?.skippedClips.map(\.clipID) ?? [])
    }

    /// Why the composition left a clip out, if it did.
    func skipReason(for clipID: Clip.ID) -> SkippedClip.Reason? {
        playback.composition?.skippedClips.first { $0.clipID == clipID }?.reason
    }

    /// The layers showing at the playhead, bottom first.
    var layerPlacements: [LayerPlacement] {
        project.layerPlacements(at: playback.currentTime, excluding: clipsLeftOutOfPicture)
    }

    /// Selects the topmost layer under a point of the frame, in render
    /// pixels, returning whether there was one. Tapping where there's none
    /// clears the selection.
    @discardableResult
    func selectLayer(at point: CGPoint) -> Bool {
        let layer = project.layer(at: point, time: playback.currentTime, excluding: clipsLeftOutOfPicture)
        if let layer {
            if layer.clipID != selectedClip?.id { timeline.editedMaskEffectID = nil }
            select(layer.clipID)
        } else {
            deselectAll()
            timeline.editedMaskEffectID = nil
        }
        return layer != nil
    }

    /// Changes a clip: at once, as an undo step of its own, or as part of a
    /// drag that `endGesture` finishes, all one undo step.
    func changeClip(_ clipID: Clip.ID, _ actionName: String, continuously: Bool = false, _ change: (inout Clip) -> Void) {
        if continuously {
            if gestureBaseline == nil { beginGesture(actionName) }
            updateGesture { $0.updateClip(clipID, change) }
        } else {
            perform(actionName) { $0.updateClip(clipID, change) }
        }
    }

    /// The clip as it was when the gesture under way began, for a drag to
    /// make its whole change from; the clip as it is when there's none.
    func clipAtGestureStart(_ clipID: Clip.ID) -> Clip? {
        (gestureBaseline ?? project).clip(id: clipID)?.clip
    }
}
