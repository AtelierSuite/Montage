import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
#if os(macOS)
import AppKit
#endif

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
            select(layer.clipID)
        } else {
            deselectAll()
        }
        return layer != nil
    }

    // MARK: - Editing text in place

    /// How soon after a tap a second one makes a double tap.
    static var doubleTapInterval: TimeInterval {
        #if os(macOS)
        NSEvent.doubleClickInterval
        #else
        0.35
        #endif
    }

    /// Notes a tap on the preview's picture, at a point of the frame. The
    /// second of a double tap on a text layer starts editing its words in
    /// place, and says so.
    func doubleTapEditsText(at point: CGPoint) -> Bool {
        let now = Date()
        let previous = timeline.lastPictureTap
        timeline.lastPictureTap = PictureTap(date: now, point: point)
        // A double tap's taps land close together: within a fiftieth of the
        // frame's width.
        let reach = project.settings.renderSize.width / 50
        guard !playback.isPlaying, let previous, now.timeIntervalSince(previous.date) <= Self.doubleTapInterval,
              hypot(point.x - previous.point.x, point.y - previous.point.y) <= reach,
              let layer = project.layer(at: point, time: playback.currentTime, excluding: clipsLeftOutOfPicture),
              project.clip(id: layer.clipID)?.clip.content.text != nil else { return false }
        timeline.lastPictureTap = nil
        beginEditingText(layer.clipID)
        return true
    }

    /// Starts typing into a text clip's words in the preview, selecting it.
    /// Everything typed until `endEditingText` is one undo step, unless
    /// another change comes between, which makes what was typed before it a
    /// step of its own.
    func beginEditingText(_ clipID: Clip.ID) {
        guard !playback.isPlaying, project.clip(id: clipID)?.clip.content.text != nil else { return }
        if timeline.editedTextClipID != nil { endEditingText() }
        timeline.selectedClipIDs = [clipID]
        timeline.editedTextClipID = clipID
    }

    /// The words being typed in the preview, tagged with their formatting
    /// as `TextContent.tagged()` tags them.
    func editText(of clipID: Clip.ID, _ string: NSAttributedString, formattings: [TextRun.Formatting]) {
        guard timeline.editedTextClipID == clipID else { return }
        if !isTypingGestureOpen { beginGesture(Self.editTextActionName) }
        updateGesture { project in
            project.updateClip(clipID) { $0.textContent.setWords(from: string, formattings: formattings) }
        }
    }

    /// Types a text clip's words in the inspector: everything typed until
    /// `endGesture` is one undo step, as in the preview.
    func typeWords(of clipID: Clip.ID, _ string: String) {
        changeClip(clipID, Self.editTextActionName, continuously: true) { $0.textContent.replaceString(with: string) }
    }

    /// Makes what's been typed in the inspector one undo step, leaving any
    /// other gesture under way, such as a drag, to go on.
    func endTypingWords() {
        if gestureActionName == Self.editTextActionName { endGesture() }
    }

    /// Stops typing in the preview, keeping what was typed as one undo step.
    /// Given a clip, only if it's that clip's words being typed.
    func endEditingText(of clipID: Clip.ID? = nil) {
        guard let edited = timeline.editedTextClipID, clipID == nil || clipID == edited else { return }
        endTypingGesture()
        timeline.editedTextClipID = nil
    }

    private static var editTextActionName: String { String(localized: "Canvas.Action.EditText") }

    /// Whether what's been typed in the preview is the gesture under way,
    /// not yet an undo step.
    private var isTypingGestureOpen: Bool {
        timeline.editedTextClipID != nil && gestureActionName == Self.editTextActionName
    }

    /// Makes what's been typed so far an undo step, so another change can
    /// start from it; typing on starts another.
    private func endTypingGesture() {
        if isTypingGestureOpen { endGesture() }
    }

    /// Changes a clip: at once, as an undo step of its own, or as part of a
    /// drag that `endGesture` finishes, all one undo step. A drag doesn't
    /// join another gesture under way, such as typing, which it would start
    /// again from before, taking back what was typed: it ends it first.
    func changeClip(_ clipID: Clip.ID, _ actionName: String, continuously: Bool = false, _ change: (inout Clip) -> Void) {
        if continuously {
            if gestureActionName != actionName { beginGesture(actionName) }
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
