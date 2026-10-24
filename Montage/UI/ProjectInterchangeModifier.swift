import MontageEngine
import MontageFormats
import SwiftUI

extension View {
    /// Importing another editor's project from the "…" menu: the file
    /// picker, the question before a project with something in it is
    /// replaced, and the report afterwards.
    func projectInterchange(
        editor: ProjectEditor, importer: MediaImporter, title: String,
        isImporting: Binding<Bool>
    ) -> some View {
        modifier(ProjectInterchangeModifier(
            editor: editor, importer: importer, title: title, isImporting: isImporting
        ))
    }
}

private struct ProjectInterchangeModifier: ViewModifier {
    let editor: ProjectEditor
    let importer: MediaImporter
    let title: String
    @Binding var isImporting: Bool

    @State private var projectImport: ProjectImport?
    /// The file chosen to import, waiting on the question before replacing.
    @State private var pendingURL: URL?

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: $isImporting, allowedContentTypes: ProjectImport.importableTypes) { result in
                guard case .success(let url) = result else { return }
                if editor.hasContent { pendingURL = url } else { start(url) }
            }
            .confirmationDialog(
                "ProjectImport.Replace.Title", isPresented: isAskingToReplace, titleVisibility: .visible,
                presenting: pendingURL
            ) { url in
                Button("ProjectImport.Action", role: .destructive) { start(url) }
                Button("ProjectImport.Cancel", role: .cancel) {}
            } message: { _ in
                Text("ProjectImport.Replace.Message")
            }
            .overlay {
                if projectImport?.isImporting == true {
                    ProjectImportProgressView()
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
            .sheet(isPresented: isShowingReport) {
                if let report = projectImport?.report {
                    ImportReportView(report: report, frames: FrameTime(frameDuration: editor.project.settings.frameDuration)) {
                        projectImport?.report = nil
                    }
                }
            }
            .alert("ProjectImport.Failed.Title", isPresented: isShowingFailure, presenting: projectImport?.failure) { _ in
                Button("ProjectImport.Failed.OK") { projectImport?.failure = nil }
            } message: { failure in
                Text(failure)
            }
    }

    private func start(_ url: URL) {
        let projectImport = projectImport ?? ProjectImport(editor: editor) { [importer] in importer.store }
        self.projectImport = projectImport
        projectImport.start(url)
    }

    private var isAskingToReplace: Binding<Bool> {
        Binding { pendingURL != nil } set: { if !$0 { pendingURL = nil } }
    }

    private var isShowingReport: Binding<Bool> {
        Binding { projectImport?.report != nil } set: { if !$0 { projectImport?.report = nil } }
    }

    private var isShowingFailure: Binding<Bool> {
        Binding { projectImport?.failure != nil } set: { if !$0 { projectImport?.failure = nil } }
    }
}
