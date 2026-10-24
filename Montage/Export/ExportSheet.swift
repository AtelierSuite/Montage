import MontageEngine
import SwiftUI

/// The "…" menu's Export: where the video goes and how it's made. The
/// export then runs in the app's queue, carrying on in the background.
struct ExportSheet: View {
    enum Destination: Hashable {
        /// Saved through the Files exporter once it's rendered.
        case files
        /// Added to the photo library, as MP4 only.
        case photos
    }

    let editor: ProjectEditor
    /// The project's name, for the file.
    let title: String
    /// Called once the export is queued.
    let didStart: () -> Void

    /// The options last used, as the next export's starting point.
    @MainActor private static var lastSettings = ExportSettings()

    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSheet.lastSettings
    @State private var destination = Destination.files
    @State private var isShowingPhotosDenied = false

    private var formats: [ExportFormat] {
        let supported = ExportFormat.allCases.filter { ExportCenter.queue.exporter.supports($0) }
        return destination == .photos ? supported.filter(\.canSaveToPhotos) : supported
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Export.Destination", selection: $destination) {
                        Label("Export.Destination.Files", systemImage: "folder").tag(Destination.files)
                        Label("Export.Destination.Photos", systemImage: "photo.on.rectangle").tag(Destination.photos)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                } footer: {
                    if destination == .photos { Text("Export.Destination.Photos.Footer") }
                }
                Section {
                    ExportOptionsForm(
                        settings: $settings, formats: formats,
                        projectSettings: editor.project.settings, duration: editor.project.duration
                    )
                }
            }
            .navigationTitle("Export.Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Export.Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export.Action", systemImage: "checkmark") { Task { await start() } }
                        .disabled(!editor.canExport)
                }
            }
            .onChange(of: destination) { _, _ in
                if !formats.contains(settings.format) { settings.format = .mp4 }
            }
            .alert("Export.Photos.NotAllowed", isPresented: $isShowingPhotosDenied) {
                Button("Library.ImportFailed.OK") {}
            } message: {
                Text("Export.Photos.NotAllowed.Message")
            }
        }
    }

    private func start() async {
        let delivery: ExportJob.Delivery
        switch destination {
        case .files:
            delivery = .hold
        case .photos:
            // Asked now, while the user is here to answer.
            guard await PhotoLibrary.requestAccess() else {
                isShowingPhotosDenied = true
                return
            }
            delivery = .deliver { url in try await PhotoLibrary.saveVideo(at: url) }
        }
        Self.lastSettings = settings
        ExportCenter.queue.enqueue(
            title: title, settings: settings, delivery: delivery, makeSource: editor.makeRenderSource()
        )
        dismiss()
        didStart()
    }
}
