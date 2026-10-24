import MontageEngine
import PhotosUI
import SwiftUI

/// The media imported into the project, ready to be added to the timeline.
struct LibraryView: View {
    @Environment(ProjectEditor.self) private var editor
    @Environment(MediaImporter.self) private var importer
    @State private var selection = Set<MediaItem.ID>()
    #if os(macOS)
    /// The item a Shift-click selects from.
    @State private var selectionAnchor: MediaItem.ID?
    @FocusState private var isGridFocused: Bool
    #endif
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
            grid
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimumCellWidth), spacing: 10)], spacing: 14) {
                ForEach(editor.project.media) { item in
                    LibraryCell(item: item, isSelected: selection.contains(item.id))
                        .contextMenu { itemMenu(ids(actingOn: item)) }
                        .accessibilityAction { select(item) }
                        .accessibilityAction(named: Text("Library.AddToTimeline")) { addToTimeline(ids(actingOn: item)) }
                        .accessibilityAction(named: Text("Library.Remove")) { remove(ids(actingOn: item)) }
                        #if os(macOS)
                        // A double-click adds to the timeline; its first click has
                        // already selected.
                        .onTapGesture(count: 2) { addToTimeline(ids(actingOn: item)) }
                        .simultaneousGesture(TapGesture().onEnded { select(item) })
                        #else
                        // A tap only selects, so a scroll can't add to the timeline by mistake.
                        .onTapGesture { select(item) }
                        #endif
                }
            }
            .padding(Self.gridPadding)
        }
        // A click between the items clears the selection.
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture { selection = [] }
        }
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .focused($isGridFocused)
        .onDeleteCommand { remove(selection) }
        #endif
    }

    #if os(macOS)
    // Two across in a sidebar of about 220 points.
    private static let minimumCellWidth: CGFloat = 88
    private static let gridPadding: CGFloat = 12
    #else
    // Three across an iPhone.
    private static let minimumCellWidth: CGFloat = 100
    private static let gridPadding: CGFloat = 16
    #endif

    /// The items an action on `item` is for: the selection if it's part of
    /// it, else the item alone.
    private func ids(actingOn item: MediaItem) -> Set<MediaItem.ID> {
        selection.contains(item.id) ? selection : [item.id]
    }

    /// Selects as a click does: alone, or with Command to toggle the item and
    /// Shift to reach it from the last one clicked. A tap on iOS toggles it.
    private func select(_ item: MediaItem) {
        #if os(macOS)
        isGridFocused = true
        let modifiers = NSEvent.modifierFlags
        let ids = editor.project.media.map(\.id)
        if modifiers.contains(.shift), let anchor = selectionAnchor,
           let from = ids.firstIndex(of: anchor), let to = ids.firstIndex(of: item.id) {
            selection.formUnion(ids[min(from, to)...max(from, to)])
            return
        }
        selectionAnchor = item.id
        if modifiers.contains(.command) {
            selection.formSymmetricDifference([item.id])
        } else {
            selection = [item.id]
        }
        #else
        selection = selection == [item.id] ? [] : [item.id]
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

/// A media item in the library: a picture of it, how long it runs, and its
/// name.
private struct LibraryCell: View {
    let item: MediaItem
    let isSelected: Bool

    static let cornerRadius: CGFloat = 10

    var body: some View {
        VStack(spacing: 5) {
            LibraryThumbnail(item: item)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Self.cornerRadius))
                .overlay(alignment: .bottomTrailing) { badge }
                .overlay {
                    RoundedRectangle(cornerRadius: Self.cornerRadius)
                        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator),
                                      lineWidth: isSelected ? 3 : 0.5)
                }
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
        }
        .contentShape(.rect(cornerRadius: Self.cornerRadius))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.name))
        .accessibilityValue(Text(accessibilityValue))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// How long the media runs, or a glyph for a still image.
    @ViewBuilder
    private var badge: some View {
        Group {
            if item.kind == .image {
                Image(systemName: "photo")
            } else if let duration = Self.duration(of: item) {
                Text(duration.formatted(.time(pattern: duration >= .seconds(3600) ? .hourMinuteSecond : .minuteSecond)))
                    .monospacedDigit()
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.black.opacity(0.6), in: .capsule)
        .padding(4)
    }

    private var accessibilityValue: String {
        let kind = switch item.kind {
        case .video: String(localized: "Library.Kind.Video")
        case .audio: String(localized: "Library.Kind.Audio")
        case .image: String(localized: "Library.Kind.Image")
        }
        guard item.kind != .image, let duration = Self.duration(of: item) else { return kind }
        return kind + ", " + duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }

    private static func duration(of item: MediaItem) -> Duration? {
        let seconds = item.metadata.duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return .milliseconds(Int64((seconds * 1000).rounded()))
    }
}

/// A picture of a media item, cropped to fill the space it's given, with its
/// kind's symbol until the picture's made, and for audio, which has none.
private struct LibraryThumbnail: View {
    let item: MediaItem
    @Environment(ProjectEditor.self) private var editor
    @Environment(\.displayScale) private var displayScale
    @State private var size = CGSize.zero
    @State private var image: CGImage?

    var body: some View {
        placeholder
            .overlay {
                if let image {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                }
            }
            .clipped()
            .animation(.easeOut(duration: 0.2), value: image != nil)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .task(id: pixelSize) { await load() }
    }

    private var placeholder: some View {
        Rectangle()
            .fill(item.kind == .audio ? AnyShapeStyle(Color.accentColor.opacity(0.25).gradient)
                                      : AnyShapeStyle(.fill.tertiary))
            .overlay {
                Image(systemName: symbolName)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }

    private var symbolName: String {
        switch item.kind {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    /// The pixels the picture covers, rounded up in steps so resizing the
    /// sidebar doesn't make a new picture for every point.
    private var pixelSize: CGSize {
        guard size.width > 0 else { return .zero }
        let step: CGFloat = 64
        let width = (size.width * displayScale / step).rounded(.up) * step
        return CGSize(width: width, height: (width * 9 / 16).rounded(.up))
    }

    private func load() async {
        guard item.kind != .audio, pixelSize != .zero, let url = editor.mediaResolver.url(for: item) else { return }
        let thumbnail = await editor.thumbnails.thumbnail(for: item, at: url, filling: pixelSize)
        guard !Task.isCancelled else { return }
        image = thumbnail
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
