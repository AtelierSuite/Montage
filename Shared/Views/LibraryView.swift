import MontageEngine
import PhotosUI
import SwiftUI

/// The media imported into the project, ready to be added to the timeline.
struct LibraryView: View {
    @Environment(ProjectEditor.self) private var editor
    @Environment(MediaImporter.self) private var importer
    @State private var selection = Set<MediaItem.ID>()
    #if os(iOS)
    @State private var isShowingPhotos = false
    @State private var isShowingFiles = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    #endif

    var body: some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .alert("Library.ImportFailed.Title", isPresented: isShowingFailures, presenting: importer.failures) { _ in
                Button("Library.ImportFailed.OK") { importer.failures = [] }
            } message: { failures in
                Text(failures.map(\.message).joined(separator: "\n\n"))
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .primaryAction) { importMenu }
            }
            .photosPicker(
                isPresented: $isShowingPhotos, selection: $pickedPhotos, matching: .any(of: [.videos, .images]),
                // As it's stored, rather than converted to something more compatible.
                preferredItemEncoding: .current
            )
            .onChange(of: pickedPhotos) { _, items in
                guard !items.isEmpty else { return }
                importer.importPhotos(items)
                pickedPhotos = []
            }
            .fileImporter(
                isPresented: $isShowingFiles, allowedContentTypes: MediaImporter.importableTypes,
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result { importer.importFiles(urls) }
            }
            #else
            // Files dragged in from the Finder.
            .dropDestination(for: URL.self) { urls, _ in
                let files = urls.filter(\.isFileURL)
                importer.importFiles(files)
                return !files.isEmpty
            }
            #endif
    }

    @ViewBuilder
    private var content: some View {
        if editor.project.media.isEmpty {
            ContentUnavailableView {
                Label("Library.Empty.Title", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("Library.Empty.Message")
            } actions: {
                #if os(iOS)
                importMenu
                    .buttonStyle(.bordered)
                #else
                Button("Library.Import", action: showOpenPanel)
                #endif
            }
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(editor.project.media) { item in
                LibraryRow(item: item)
                    #if os(iOS)
                    .swipeActions(edge: .trailing) {
                        Button("Library.Remove", systemImage: "trash", role: .destructive) {
                            remove([item.id])
                        }
                    }
                    .swipeActions(edge: .leading) {
                        Button("Library.AddToTimeline", systemImage: "plus") { addToTimeline([item.id]) }
                            .tint(.accentColor)
                    }
                    #endif
            }
        }
        #if os(macOS)
        .contextMenu(forSelectionType: MediaItem.ID.self, menu: itemMenu) { ids in
            // A double-click adds to the timeline.
            addToTimeline(ids)
        }
        .onDeleteCommand { remove(selection) }
        #else
        // A tap does nothing, so a scroll can't add to the timeline by mistake.
        .contextMenu(forSelectionType: MediaItem.ID.self, menu: itemMenu)
        #endif
    }

    @ViewBuilder
    private func itemMenu(_ ids: Set<MediaItem.ID>) -> some View {
        if !ids.isEmpty {
            Button("Library.AddToTimeline", systemImage: "plus.rectangle.on.rectangle") { addToTimeline(ids) }
            Divider()
            Button("Library.Remove", systemImage: "trash", role: .destructive) { remove(ids) }
        }
    }

    /// Adds the items to the timeline in the order the library lists them.
    private func addToTimeline(_ ids: Set<MediaItem.ID>) {
        editor.addToTimeline(editor.project.media.map(\.id).filter(ids.contains))
    }

    private func remove(_ ids: Set<MediaItem.ID>) {
        guard !ids.isEmpty else { return }
        editor.removeFromLibrary(ids)
        selection.subtract(ids)
    }

    // MARK: - Importing

    private var isShowingFailures: Binding<Bool> {
        Binding { !importer.failures.isEmpty } set: { if !$0 { importer.failures = [] } }
    }

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 0) {
            if let progress = importer.progress {
                ImportProgressRow(progress: progress)
                    .padding()
            }
            #if os(macOS)
            if !editor.project.media.isEmpty {
                HStack {
                    Button("Library.Import", systemImage: "plus", action: showOpenPanel)
                        .labelStyle(.iconOnly)
                        .help(Text("Library.Import"))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            #endif
        }
        .background(.bar)
    }

    #if os(iOS)
    private var importMenu: some View {
        Menu("Library.Import", systemImage: "plus") {
            Button("Library.Import.Photos", systemImage: "photo.on.rectangle") { isShowingPhotos = true }
            Button("Library.Import.Files", systemImage: "folder") { isShowingFiles = true }
        }
    }
    #else
    /// Asks the window to show its open panel, as File > Import does.
    private func showOpenPanel() {
        NSApp.sendAction(Selector(("importMedia:")), to: nil, from: nil)
    }
    #endif
}

/// A media item in the library: its kind, name and length.
private struct LibraryRow: View {
    let item: MediaItem

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: symbolName)
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    private var detail: String {
        guard item.kind != .image else { return String(localized: "Library.Kind.Image") }
        let seconds = item.metadata.duration.seconds
        guard seconds.isFinite else { return "" }
        let duration = Duration.milliseconds(Int64((seconds * 1000).rounded()))
        return duration.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// How far an import has got.
private struct ImportProgressRow: View {
    let progress: MediaImporter.Progress

    var body: some View {
        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))) {
            Text(String(format: String(localized: "Library.Importing"),
                        min(progress.completed + 1, progress.total), progress.total))
        } currentValueLabel: {
            if let name = progress.currentName {
                Text(name).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.callout)
    }
}
