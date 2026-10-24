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

    /// Puts stills from the library at a time, over the video there, one
    /// after the other.
    func addStills(_ ids: [MediaItem.ID], at time: CMTime) {
        let items = ids.compactMap { project.mediaItem(id: $0) }.filter { $0.kind == .image }
        guard !items.isEmpty else { return }
        var added: [Clip.ID] = []
        perform(String(localized: "Action.AddImage")) { project in
            var start = time
            for item in items {
                added.append(project.insertClip(of: item.content, at: start))
                start = start + Project.defaultImageDuration
            }
        }
        timeline.selectedClipIDs = Set(added)
    }

    /// Changes a clip: at once, as an undo step of its own, or as part of a
    /// drag that `endClipChange` finishes.
    func changeClip(_ clipID: Clip.ID, continuously: Bool = false, _ change: (inout Clip) -> Void) {
        let name = String(localized: "Inspector.Action.ChangeClip")
        if continuously {
            if gestureBaseline == nil { beginGesture(name) }
            updateGesture { $0.updateClip(clipID, change) }
        } else {
            perform(name) { $0.updateClip(clipID, change) }
        }
    }

    func endClipChange() {
        endGesture()
    }
}

extension Project {
    /// Changes a clip in place on whichever track holds it.
    mutating func updateClip(_ id: Clip.ID, _ change: (inout Clip) -> Void) {
        guard let (index, _) = location(of: id) else { return }
        tracks[index].update(id, change)
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
