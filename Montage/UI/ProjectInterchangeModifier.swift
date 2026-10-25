import MontageEngine
import MontageFormats
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Importing another editor's project, and exporting this one as FCPXML
    /// or OpenTimelineIO, from the "…" menu: the file pickers, the question before a project
    /// with something in it is replaced, and the report afterwards.
    func projectInterchange(
        editor: ProjectEditor, importer: MediaImporter, title: String,
        isImporting: Binding<Bool>, isExporting: Binding<Bool>, isExportingOTIO: Binding<Bool>
    ) -> some View {
        modifier(ProjectInterchangeModifier(
            editor: editor, importer: importer, title: title, isImporting: isImporting, isExporting: isExporting,
            isExportingOTIO: isExportingOTIO
        ))
    }
}

private struct ProjectInterchangeModifier: ViewModifier {
    let editor: ProjectEditor
    let importer: MediaImporter
    let title: String
    @Binding var isImporting: Bool
    @Binding var isExporting: Bool
    @Binding var isExportingOTIO: Bool

    @State private var projectImport: ProjectImport?
    /// The file chosen to import, waiting on the question before replacing.
    @State private var pendingURL: URL?
    @State private var exported: InterchangeFile?
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
                exported = InterchangeFile(data: editor.fcpxml(named: title), type: .fcpxml, fileExtension: "fcpxml")
                isShowingExporter = true
                isExporting = false
            }
            .onChange(of: isExportingOTIO) { _, wantsExport in
                guard wantsExport else { return }
                exported = InterchangeFile(data: editor.otio(named: title), type: .otio, fileExtension: "otio")
                isShowingExporter = true
                isExportingOTIO = false
            }
            .fileExporter(
                isPresented: $isShowingExporter, document: exported, contentType: exported?.type ?? .fcpxml,
                defaultFilename: "\(title).\(exported?.fileExtension ?? "fcpxml")"
            ) { result in
                switch result {
                case .success: if exported?.type == .fcpxml { exportOmission = editor.fcpxmlOmissionMessage }
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

/// An exported FCPXML or OpenTimelineIO file, for the file exporter to save.
private struct InterchangeFile: FileDocument {
    static let readableContentTypes: [UTType] = [.fcpxml, .otio]

    let data: Data
    let type: UTType
    let fileExtension: String

    init(data: Data, type: UTType, fileExtension: String) {
        self.data = data
        self.type = type
        self.fileExtension = fileExtension
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
        type = configuration.contentType
        fileExtension = configuration.contentType.preferredFilenameExtension ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
