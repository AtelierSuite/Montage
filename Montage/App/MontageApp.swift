import MontageFormats
import SwiftUI

@main
struct MontageApp: App {
    @State private var launchReveal = DocumentLaunchReveal()

    init() {
        // Exports keep going when the user leaves the app.
        let queue = ExportCenter.queue
        queue.observers.append(BackgroundExports(queue: queue))
    }

    var body: some Scene {
        DocumentGroup(newDocument: MontageDocument()) { configuration in
            ProjectEditorView(document: configuration.$document, fileURL: configuration.fileURL)
        }

        DocumentGroupLaunchScene(Text(verbatim: "")) {
            NewDocumentButton("Launch.NewProject", contentType: .montageProject)
        } background: {
            DocumentLaunchBackground(reveal: launchReveal)
        } backgroundAccessoryView: { _ in
            DocumentLaunchRevealTrigger(reveal: launchReveal)
        }
    }
}
