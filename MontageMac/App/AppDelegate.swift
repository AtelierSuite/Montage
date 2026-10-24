import AppKit
import MontageFormats
import UniformTypeIdentifiers

/// The Mac app: an AppKit document app, one window per project.
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The application holds its delegate weakly.
    private static let shared = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = shared
        application.mainMenu = MainMenu.make()
        application.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Ahead of the first window: the document controller has to exist
        // before anything asks for `NSDocumentController.shared`.
        _ = DocumentController.shared
        // A plain launch should begin with the standard open dialog.
        // Defer until AppKit has finished restoring or opening launch items.
        DispatchQueue.main.async { [weak self] in
            guard let self, NSApp.orderedDocuments.isEmpty else { return }
            DocumentController.shared.openDocument(self)
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { false }

    // MARK: - Exports

    /// Window > Exports.
    @objc func showExports(_ sender: Any?) {
        ExportsWindowController.shared.showWindow(sender)
    }

    /// Exports carry on with their windows closed, so quitting asks first,
    /// then waits for them to stop and clean up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let queue = ExportCenter.queue
        guard queue.hasActiveJobs else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "Export.Quit.Title")
        alert.informativeText = String(localized: "Export.Quit.Message")
        alert.addButton(withTitle: String(localized: "Export.Quit.Continue"))
        alert.addButton(withTitle: String(localized: "Export.Quit.Quit"))
        guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        queue.cancelAll()
        Task {
            while queue.hasActiveJobs { try? await Task.sleep(for: .milliseconds(50)) }
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The app's document controller, made first so it is the shared one.
final class DocumentController: NSDocumentController {
    override var defaultType: String? { UTType.montageProject.identifier }
}
