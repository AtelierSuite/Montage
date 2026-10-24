import MontageFormats
import SwiftUI

@main
struct MontageApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MontageDocument()) { configuration in
            ProjectEditorView(document: configuration.$document)
        }

        DocumentGroupLaunchScene {
            NewDocumentButton("Launch.NewProject", contentType: .montageProject)
        } background: {
            DocumentLaunchBackground()
        }
    }
}
