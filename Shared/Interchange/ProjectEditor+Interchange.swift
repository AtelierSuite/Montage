import Foundation
import MontageEngine

/// Projects from other editors.
extension ProjectEditor {
    /// Whether importing a project would replace anything: a library or a
    /// timeline with something in it.
    var hasContent: Bool {
        !project.media.isEmpty || project.tracks.contains { !$0.clips.isEmpty }
    }

    /// Puts an imported project in place of this one, as one undo step.
    func replaceContents(with imported: Project) {
        perform(String(localized: "Action.ImportProject")) { $0 = imported }
    }
}
