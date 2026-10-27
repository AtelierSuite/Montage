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

    /// What to tell the user an FCPXML export left out, or nil if nothing.
    var fcpxmlOmissionMessage: String? {
        let count = ProjectInterchange.clipsLeftOutOfFCPXML(in: project).count
        guard count > 0 else { return nil }
        return String(format: String(localized: "FCPXMLExport.LeftOut.Message"), count)
    }

    /// The project as FCPXML, for Final Cut Pro.
    func fcpxml(named name: String) -> Data {
        ProjectInterchange.fcpxml(for: project, named: name, mediaResolver: mediaResolver)
    }

    /// What to tell the user an EDL export left out, or nil if nothing.
    var edlOmissionMessage: String? {
        let count = ProjectInterchange.clipsLeftOutOfEDL(in: project).count
        guard count > 0 else { return nil }
        return String(format: String(localized: "EDLExport.LeftOut.Message"), count)
    }

    /// The project as a CMX 3600 EDL, for editors that read cut lists.
    func edl(named name: String) -> Data {
        ProjectInterchange.edl(for: project, named: name, mediaResolver: mediaResolver)
    }

    /// The project as OpenTimelineIO, for Resolve, Premiere Pro and others.
    func otio(named name: String) -> Data {
        ProjectInterchange.otio(for: project, named: name, mediaResolver: mediaResolver)
    }
}
