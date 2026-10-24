import AppKit
import CoreMedia
import MontageEngine
import SwiftUI

/// File > Export: a save panel with the export options as its accessory.
/// The export renders to a temporary file and is moved to where the user
/// chose once it's done.
@MainActor
enum ExportSavePanel {
    /// The options last used, as the next export's starting point.
    private static var lastSettings = ExportSettings()

    static func begin(for window: NSWindow, editor: ProjectEditor, title: String) {
        let model = Model(settings: lastSettings)
        let formats = ExportFormat.allCases.filter { ExportCenter.queue.exporter.supports($0) }
        if !formats.contains(model.settings.format) { model.settings.format = .mp4 }

        let panel = NSSavePanel()
        panel.title = String(localized: "Export.Title")
        panel.prompt = String(localized: "Export.Action")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [model.settings.format.contentType]
        panel.nameFieldStringValue = "\(title).\(model.settings.format.fileExtension)"

        let accessory = NSHostingView(rootView: Accessory(
            model: model, formats: formats, projectSettings: editor.project.settings, duration: editor.project.duration
        ) { [weak panel] format in
            guard let panel else { return }
            panel.allowedContentTypes = [format.contentType]
            let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(name).\(format.fileExtension)"
        })
        accessory.frame.size = accessory.fittingSize
        panel.accessoryView = accessory

        let makeSource = editor.makeRenderSource()
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let destination = panel.url else { return }
            MainActor.assumeIsolated {
                lastSettings = model.settings
                let name = destination.deletingPathExtension().lastPathComponent
                ExportCenter.queue.enqueue(title: name, settings: model.settings, delivery: .deliver { file in
                    try moveFile(at: file, to: destination)
                }, makeSource: makeSource)
                ExportsWindowController.shared.showWindow(nil)
            }
        }
    }

    private static func moveFile(at file: URL, to destination: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: file)
        } else {
            try manager.moveItem(at: file, to: destination)
        }
    }

    @MainActor
    @Observable
    final class Model {
        var settings: ExportSettings

        init(settings: ExportSettings) {
            self.settings = settings
        }
    }

    private struct Accessory: View {
        @Bindable var model: Model
        let formats: [ExportFormat]
        let projectSettings: ProjectSettings
        let duration: CMTime
        let formatChanged: (ExportFormat) -> Void

        var body: some View {
            Form {
                ExportOptionsForm(
                    settings: $model.settings, formats: formats, projectSettings: projectSettings, duration: duration
                )
            }
            .formStyle(.columns)
            .fixedSize()
            .padding(20)
            .onChange(of: model.settings.format) { _, format in formatChanged(format) }
        }
    }
}
