import Foundation
import MontageEngine

/// Changes to the library, and adding from it to the timeline.
extension ProjectEditor {
    /// Adds imported media to the library, as one undo step.
    func addMedia(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        perform(String(localized: "Action.ImportMedia")) { $0.addMedia(items) }
    }

    /// Puts each item, whole, at the end of the first track of its kind:
    /// video and images on the first video track, audio on the first audio
    /// track, making the track if there's none.
    func addToTimeline(_ ids: [MediaItem.ID]) {
        perform(String(localized: "Action.AddToTimeline")) { project in
            for id in ids { project.appendClip(of: id) }
        }
    }

    /// Takes media out of the library, and its clips off the timeline. The
    /// files stay in the package, so undo can bring them back.
    func removeFromLibrary(_ ids: Set<MediaItem.ID>) {
        perform(String(localized: "Action.RemoveFromLibrary")) { $0.removeMedia(ids) }
    }
}
