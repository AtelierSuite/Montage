import MontageEngine
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Importing another editor's project from the "…" menu: the file
    /// picker, the question before a project with something in it is
    /// replaced, and the report afterwards.
    func projectInterchange(
        editor: ProjectEditor, importer: MediaImporter, title: String, isImporting: Binding<Bool>
    ) -> some View {
        modifier(ProjectInterchangeModifier(editor: editor, importer: importer, title: title, isImporting: isImporting))
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
    /// The import's request for a folder its media could be in, waiting on
    /// the user.
    @State private var folderRequest: FolderRequest?
    @State private var isPickingFolder = false

    func body(content: Content) -> some View {
        askingForFolders(content)
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
                    ImportReportView(
                        report: report.contents, timelineName: report.timelineName, documentName: title,
                        frames: FrameTime(frameDuration: editor.project.settings.frameDuration)
                    ) {
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

    /// The question when an import can't read the folder its media could be
    /// in, and the folder picker that follows.
    private func askingForFolders(_ content: Content) -> some View {
        content
            .alert("ProjectImport.FolderAccess.Title", isPresented: isAskingForFolder, presenting: folderRequest) { _ in
                Button("ProjectImport.FolderAccess.Choose") { isPickingFolder = true }
                Button("ProjectImport.FolderAccess.Skip", role: .cancel) { finishFolderRequest(with: nil) }
            } message: { request in
                Text(String(format: String(localized: "ProjectImport.FolderAccess.Message"), request.folder.lastPathComponent))
            }
            // Apart from the project's file importer, which it would replace.
            .background {
                Color.clear
                    .fileImporter(
                        isPresented: $isPickingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false
                    ) { result in
                        finishFolderRequest(with: (try? result.get())?.first)
                    } onCancellation: {
                        finishFolderRequest(with: nil)
                    }
                    .fileDialogDefaultDirectory(folderRequest?.folder)
            }
    }

    private func start(_ url: URL) {
        let projectImport = projectImport ?? ProjectImport(editor: editor) { [importer] in importer.store }
        self.projectImport = projectImport
        projectImport.requestFolderAccess = { folder in
            await withCheckedContinuation { continuation in
                folderRequest = FolderRequest(folder: folder, continuation: continuation)
            }
        }
        projectImport.start(url)
    }

    private func finishFolderRequest(with folder: URL?) {
        folderRequest?.continuation.resume(returning: folder)
        folderRequest = nil
        isPickingFolder = false
    }

    private var isAskingForFolder: Binding<Bool> {
        Binding { folderRequest != nil && !isPickingFolder } set: { _ in }
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

/// A folder an import asks access to, and where the answer goes.
private struct FolderRequest {
    let folder: URL
    let continuation: CheckedContinuation<URL?, Never>
}
