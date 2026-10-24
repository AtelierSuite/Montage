import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine

/// Adding text, shapes and stills at the playhead, and changing a clip's own
/// settings from the inspector.
extension ProjectEditor {
    /// Where an added layer starts: the frame the playhead shows.
    var insertionTime: CMTime {
        playback.frames.snapped(playback.currentTime)
    }

    /// Puts a text clip at the playhead, over the video there, and selects
    /// it for the inspector.
    func addText() {
        let text = TextContent(String(localized: "Text.Default"))
        add(.text(text), actionName: String(localized: "Action.AddText"))
    }

    /// Puts a shape at the playhead, over the video there, and selects it.
    func addShape(_ kind: ShapeContent.Kind) {
        add(.shape(.defaults(for: kind)), actionName: String(localized: "Action.AddShape"))
    }

    private func add(_ content: ClipContent, actionName: String) {
        let time = insertionTime
        var id: Clip.ID?
        perform(actionName) { id = $0.insertClip(of: content, at: time) }
        if let id { timeline.selectedClipIDs = [id] }
    }

    /// Adds imported media to the library and puts the stills among it at a
    /// time, over the video there, one after the other: one undo step.
    func addMedia(_ items: [MediaItem], placingStillsAt time: CMTime) {
        guard !items.isEmpty else { return }
        let stills = items.filter { $0.kind == .image }
        var added: [Clip.ID] = []
        perform(String(localized: stills.isEmpty ? "Action.ImportMedia" : "Action.AddImage")) { project in
            project.addMedia(items)
            var start = time
            for item in stills {
                added.append(project.insertClip(of: item.content, at: start))
                start = start + Project.defaultImageDuration
            }
        }
        if !added.isEmpty { timeline.selectedClipIDs = Set(added) }
    }

    /// Changes a clip: at once, as an undo step of its own, or as part of a
    /// drag that `endClipChange` finishes.
    func changeClip(_ clipID: Clip.ID, continuously: Bool = false, _ change: (inout Clip) -> Void) {
        changeClip(clipID, String(localized: "Inspector.Action.ChangeClip"), continuously: continuously, change)
    }

    func endClipChange() {
        endGesture()
    }
}

/// A text or shape clip's content, reached by key path, so a control can
/// edit part of it without unpacking the clip's content.
extension Clip {
    var textContent: TextContent {
        get { content.text ?? TextContent() }
        set { if case .text = content { content = .text(newValue) } }
    }

    var shapeContent: ShapeContent {
        get { content.shape ?? ShapeContent() }
        set { if case .shape = content { content = .shape(newValue) } }
    }
}
