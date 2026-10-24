import AppKit
import MontageEngine
import MontageFormats
import SwiftUI

/// File > Import Project: projects from other editors.
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
}
