import Foundation
import MontageEngine
import MontageFormats

/// Projects to and from other editors.
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

    /// The project as FCPXML, for Final Cut Pro.
    func fcpxml(named name: String) -> Data {
        ProjectInterchange.fcpxml(for: project, named: name, mediaResolver: mediaResolver)
    }
}
