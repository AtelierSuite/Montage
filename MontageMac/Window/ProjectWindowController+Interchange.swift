import AppKit
import MontageEngine
import MontageFormats
import SwiftUI
import UniformTypeIdentifiers

/// File > Import Project, File > Export Final Cut Pro XML and File > Export
/// EDL and File > Export OpenTimelineIO: projects to and from other editors.
extension ProjectWindowController {
    // MARK: - Importing

    /// Chooses another editor's project to put in place of this one.
    @objc func importProject(_ sender: Any?) {
        guard let window, !projectImport.isImporting else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ProjectImport.importableTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = String(localized: "ProjectImport.Action")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            MainActor.assumeIsolated { self?.confirmReplacing { self?.beginImport(from: url) } }
        }
    }

    /// Asks before an import replaces a project with something in it.
    private func confirmReplacing(_ proceed: @escaping () -> Void) {
        guard editor.hasContent, let window else {
            proceed()
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "ProjectImport.Replace.Title")
        alert.informativeText = String(localized: "ProjectImport.Replace.Message")
        alert.addButton(withTitle: String(localized: "ProjectImport.Action"))
        alert.addButton(withTitle: String(localized: "ProjectImport.Cancel"))
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    private func beginImport(from url: URL) {
        let progress = NSHostingController(rootView: ProjectImportProgressView())
        projectImport.onFinish = { [weak self, weak progress] in
            if let progress { progress.presentingViewController?.dismiss(progress) }
            self?.showImportOutcome()
        }
        contentViewController?.presentAsSheet(progress)
        projectImport.start(url)
    }

    /// The report of what came across, or why nothing did.
    private func showImportOutcome() {
        if let failure = projectImport.failure, let window {
            projectImport.failure = nil
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "ProjectImport.Failed.Title")
            alert.informativeText = failure
            alert.beginSheetModal(for: window)
        } else if let report = projectImport.report {
            projectImport.report = nil
            var sheet: NSViewController?
            let view = ImportReportView(
                report: report, frames: FrameTime(frameDuration: editor.project.settings.frameDuration)
            ) { if let sheet { sheet.presentingViewController?.dismiss(sheet) } }
            let controller = NSHostingController(rootView: view)
            sheet = controller
            contentViewController?.presentAsSheet(controller)
        }
    }

    // MARK: - Exporting

    /// Writes the project as FCPXML, to open in Final Cut Pro.
    @objc func exportFCPXML(_ sender: Any?) {
        export(as: .fcpxml, fileExtension: "fcpxml", contents: { $0.fcpxml(named: $1) }, omission: { $0.fcpxmlOmissionMessage })
    }

    /// Writes the project as a CMX 3600 EDL, for editors that read cut lists.
    @objc func exportEDL(_ sender: Any?) {
        export(as: .edl, fileExtension: "edl", contents: { $0.edl(named: $1) }, omission: { $0.edlOmissionMessage })
    }

    /// Asks where to save the project as another editor's file, writes it,
    /// and says what it had to leave out.
    private func export(
        as contentType: UTType, fileExtension: String, contents: @escaping (ProjectEditor, String) -> Data,
        omission: @escaping (ProjectEditor) -> String?
    ) {
        guard let window, editor.canExport else { return }
        let title = (document as? NSDocument)?.displayName ?? String(localized: "Export.Untitled")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "\(title).\(fileExtension)"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                do {
                    try contents(self.editor, destination.deletingPathExtension().lastPathComponent)
                        .write(to: destination, options: .atomic)
                    if let message = omission(self.editor) {
                        let alert = NSAlert()
                        alert.messageText = String(localized: "FCPXMLExport.LeftOut.Title")
                        alert.informativeText = message
                        alert.beginSheetModal(for: window)
                    }
                } catch {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            }
        }
    }

    /// Writes the project as OpenTimelineIO, to open in Resolve, Premiere
    /// Pro and other apps that read it.
    @objc func exportOTIO(_ sender: Any?) {
        export(as: .otio, fileExtension: "otio", contents: { $0.otio(named: $1) }, omission: { _ in nil })
    }
}
