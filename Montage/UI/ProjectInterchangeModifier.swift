import MontageEngine
import MontageFormats
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Importing another editor's project, and exporting this one as FCPXML,
    /// from the "…" menu: the file pickers, the question before a project
    /// with something in it is replaced, and the report afterwards.
    func projectInterchange(
        editor: ProjectEditor, importer: MediaImporter, title: String,
        isImporting: Binding<Bool>, isExporting: Binding<Bool>
    ) -> some View {
        modifier(ProjectInterchangeModifier(
            editor: editor, importer: importer, title: title, isImporting: isImporting, isExporting: isExporting
        ))
    }
}

private struct ProjectInterchangeModifier: ViewModifier {
    let editor: ProjectEditor
    let importer: MediaImporter
    let title: String
    @Binding var isImporting: Bool
    @Binding var isExporting: Bool

    @State private var projectImport: ProjectImport?
    /// The file chosen to import, waiting on the question before replacing.
    @State private var pendingURL: URL?
    @State private var exported: FCPXMLFile?
    @State private var isShowingExporter = false
    @State private var exportFailure: String?
    /// What a finished FCPXML export had to leave out.
    @State private var exportOmission: String?

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
            // Written when asked for, then saved wherever the user chooses.
            .onChange(of: isExporting) { _, wantsExport in
                guard wantsExport else { return }
                exported = FCPXMLFile(data: editor.fcpxml(named: title))
                isShowingExporter = true
                isExporting = false
            }
            .fileExporter(
                isPresented: $isShowingExporter, document: exported, contentType: .fcpxml, defaultFilename: "\(title).fcpxml"
            ) { result in
                switch result {
                case .success: exportOmission = editor.fcpxmlOmissionMessage
                case .failure(let error): exportFailure = error.localizedDescription
                }
                exported = nil
            }
            .alert("FCPXMLExport.Failed.Title", isPresented: isShowingExportFailure, presenting: exportFailure) { _ in
                Button("ProjectImport.Failed.OK") { exportFailure = nil }
            } message: { failure in
                Text(failure)
            }
            .alert("FCPXMLExport.LeftOut.Title", isPresented: Binding {
                exportOmission != nil
            } set: { if !$0 { exportOmission = nil } }, presenting: exportOmission) { _ in
                Button("ProjectImport.Failed.OK") { exportOmission = nil }
            } message: { message in
                Text(message)
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

    private var isShowingExportFailure: Binding<Bool> {
        Binding { exportFailure != nil } set: { if !$0 { exportFailure = nil } }
    }
}

/// An exported FCPXML file, for the file exporter to save.
private struct FCPXMLFile: FileDocument {
    static let readableContentTypes: [UTType] = [.fcpxml]

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
