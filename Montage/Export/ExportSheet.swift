import MontageEngine
import MontageFormats
import SwiftUI
import UniformTypeIdentifiers

/// The "…" menu's Export, for everything the project can be exported as: a
/// video, which runs in the app's queue, carrying on in the background, or
/// its timeline for another editor. The queue's exports are a page of it.
struct ExportSheet: View {
    enum Kind: Hashable {
        /// A rendered video.
        case video
        /// The timeline as FCPXML, an EDL or OpenTimelineIO.
        case timeline
    }

    enum Destination: Hashable {
        /// Saved through the Files exporter once it's rendered.
        case files
        /// Added to the photo library, as MP4 only.
        case photos
    }

    /// The sheet's pages past its first.
    enum Page: Hashable {
        case exports
    }

    let editor: ProjectEditor
    /// The project's name, for the file.
    let title: String

    /// The options last used, as the next export's starting point.
    @MainActor private static var lastSettings = ExportSettings()
    @MainActor private static var lastKind = Kind.video
    @MainActor private static var lastTimelineFormat = TimelineFormat.fcpxml

    @Environment(\.dismiss) private var dismiss
    @State private var path: [Page] = []
    @State private var kind = ExportSheet.lastKind
    @State private var settings = ExportSheet.lastSettings
    @State private var destination = Destination.files
    @State private var timelineFormat = ExportSheet.lastTimelineFormat
    @State private var isShowingPhotosDenied = false
    @State private var timelineFile: TimelineFile?
    @State private var isShowingTimelineExporter = false
    @State private var timelineFailure: String?
    /// What a saved timeline had to leave out.
    @State private var timelineOmission: String?

    private var queue: ExportQueue { ExportCenter.queue }

    private var formats: [ExportFormat] {
        let supported = ExportFormat.allCases.filter { queue.exporter.supports($0) }
        return destination == .photos ? supported.filter(\.canSaveToPhotos) : supported
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    Picker("Export.Kind", selection: $kind) {
                        Text("Export.Kind.Video").tag(Kind.video)
                        Text("Export.Kind.Timeline").tag(Kind.timeline)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                switch kind {
                case .video: videoOptions
                case .timeline: timelineOptions
                }
                if !queue.jobs.isEmpty {
                    Section {
                        NavigationLink(value: Page.exports) {
                            Label("Export.Progress.Title", systemImage: "list.bullet")
                        }
                    }
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
            .navigationDestination(for: Page.self) { _ in
                ExportsView(queue: queue) { dismiss() }
            }
            .onChange(of: destination) { _, _ in
                if !formats.contains(settings.format) { settings.format = .mp4 }
            }
            .alert("Export.Photos.NotAllowed", isPresented: $isShowingPhotosDenied) {
                Button("Library.ImportFailed.OK") {}
            } message: {
                Text("Export.Photos.NotAllowed.Message")
            }
            // Written when asked for, then saved wherever the user chooses.
            .fileExporter(
                isPresented: $isShowingTimelineExporter, document: timelineFile,
                contentTypes: [timelineFile?.format.contentType ?? .fcpxml],
                defaultFilename: "\(title).\(timelineFile?.format.fileExtension ?? "fcpxml")"
            ) { result in
                switch result {
                case .success:
                    // Left open to say what was left out; closed once it's read.
                    if let omission = timelineFile?.omission { timelineOmission = omission } else { dismiss() }
                case .failure(let error):
                    timelineFailure = error.localizedDescription
                }
                timelineFile = nil
            } onCancellation: {
                timelineFile = nil
            }
            .alert("FCPXMLExport.Failed.Title", isPresented: isShowingTimelineFailure, presenting: timelineFailure) { _ in
                Button("ProjectImport.Failed.OK") { timelineFailure = nil }
            } message: { failure in
                Text(failure)
            }
            .alert("FCPXMLExport.LeftOut.Title", isPresented: isShowingTimelineOmission, presenting: timelineOmission) { _ in
                Button("ProjectImport.Failed.OK") { dismiss() }
            } message: { message in
                Text(message)
            }
        }
    }

    @ViewBuilder
    private var videoOptions: some View {
        Section {
            Picker("Export.Destination", selection: $destination) {
                Label("Export.Destination.Files", systemImage: "folder").tag(Destination.files)
                Label("Export.Destination.Photos", systemImage: "photo.on.rectangle").tag(Destination.photos)
            }
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

    private var timelineOptions: some View {
        Section {
            Picker("Export.Format", selection: $timelineFormat) {
                ForEach(TimelineFormat.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
        } footer: {
            Text(timelineFormat.footer)
        }
    }

    private func start() async {
        Self.lastKind = kind
        switch kind {
        case .video: await startVideo()
        case .timeline: startTimeline()
        }
    }

    private func startVideo() async {
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
        queue.enqueue(title: title, settings: settings, delivery: delivery, makeSource: editor.makeRenderSource())
        // On to the queue, which brings up the Files exporter once it's rendered.
        path = [.exports]
    }

    private func startTimeline() {
        Self.lastTimelineFormat = timelineFormat
        timelineFile = TimelineFile(format: timelineFormat, editor: editor, title: title)
        isShowingTimelineExporter = true
    }

    private var isShowingTimelineFailure: Binding<Bool> {
        Binding { timelineFailure != nil } set: { if !$0 { timelineFailure = nil } }
    }

    private var isShowingTimelineOmission: Binding<Bool> {
        Binding { timelineOmission != nil } set: { if !$0 { timelineOmission = nil } }
    }
}

/// The formats another editor reads a timeline in.
enum TimelineFormat: CaseIterable, Hashable {
    case fcpxml
    case edl
    case otio

    var title: String {
        switch self {
        case .fcpxml: "Final Cut Pro XML"
        case .edl: "EDL"
        case .otio: "OpenTimelineIO"
        }
    }

    var footer: LocalizedStringKey {
        switch self {
        case .fcpxml: "Export.Timeline.FCPXML.Footer"
        case .edl: "Export.Timeline.EDL.Footer"
        case .otio: "Export.Timeline.OTIO.Footer"
        }
    }

    var contentType: UTType {
        switch self {
        case .fcpxml: .fcpxml
        case .edl: .edl
        case .otio: .otio
        }
    }

    var fileExtension: String {
        switch self {
        case .fcpxml: "fcpxml"
        case .edl: "edl"
        case .otio: "otio"
        }
    }
}

/// An exported FCPXML, EDL or OpenTimelineIO file, for the file exporter
/// to save, with what it had to leave out.
private struct TimelineFile: FileDocument {
    static let readableContentTypes: [UTType] = [.fcpxml, .edl, .otio]

    let data: Data
    var format = TimelineFormat.fcpxml
    var omission: String?

    @MainActor
    init(format: TimelineFormat, editor: ProjectEditor, title: String) {
        self.format = format
        switch format {
        case .fcpxml:
            data = editor.fcpxml(named: title)
            omission = editor.fcpxmlOmissionMessage
        case .edl:
            data = editor.edl(named: title)
            omission = editor.edlOmissionMessage
        case .otio:
            data = editor.otio(named: title)
        }
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
