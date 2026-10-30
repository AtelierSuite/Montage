import MontageEngine
import SwiftUI
import UniformTypeIdentifiers

/// The app's exports, a page of the Export sheet, with the Files exporter
/// for those rendered for Files: it comes up by itself when one is ready, or
/// from its Save button.
struct ExportsView: View {
    let queue: ExportQueue
    /// Closes the sheet.
    let done: () -> Void

    @State private var saving: SavingFile?
    @State private var isShowingExporter = false

    var body: some View {
        ExportProgressView(queue: queue) { job, url in save(job, url) }
            .navigationTitle("Export.Progress.Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export.Progress.Done", systemImage: "checkmark") { done() }
                }
            }
        .fileExporter(
            isPresented: $isShowingExporter, document: saving.map { ExportedFile(url: $0.url) },
            contentTypes: [saving?.job.settings.format.contentType ?? .mpeg4Movie],
            defaultFilename: saving?.job.fileName
        ) { result in
            // Saved: the copy in the temporary folder can go. Otherwise it
            // stays, to be saved again from its row.
            if case .success = result { saving?.job.discardFile() }
            saving = nil
        } onCancellation: {
            saving = nil
        }
        .onChange(of: readyJob?.id, initial: true) { _, _ in
            guard saving == nil, let job = readyJob, case .readyToSave(let url) = job.state else { return }
            save(job, url)
        }
    }

    /// The newest export waiting to be saved.
    private var readyJob: ExportJob? {
        queue.jobs.last { if case .readyToSave = $0.state { true } else { false } }
    }

    private func save(_ job: ExportJob, _ url: URL) {
        saving = SavingFile(job: job, url: url)
        isShowingExporter = true
    }

    private struct SavingFile {
        let job: ExportJob
        let url: URL
    }
}

/// A rendered export, handed to the Files exporter as a document. Its file
/// wrapper reads the movie lazily, so saving it doesn't load it into memory.
/// (Handing it over as a `Transferable` file crashes the exporter, which
/// throws while naming its own file wrapper for it.)
struct ExportedFile: FileDocument {
    static let readableContentTypes: [UTType] = [.mpeg4Movie, .avi]

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        // Only ever written out.
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url)
    }
}
