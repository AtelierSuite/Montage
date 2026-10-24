import MontageEngine
import PhotosUI
import SwiftUI

/// The media imported into the project, ready to be added to the timeline.
struct LibraryView: View {
    @Environment(ProjectEditor.self) private var editor
    @Environment(MediaImporter.self) private var importer
    @State private var selection = Set<MediaItem.ID>()
    /// Which bin, kinds and names the library shows, and in what order.
    @State private var query = LibraryQuery()
    @State private var isShowingRelink = false
    /// The bin being named: a new one, or one being renamed.
    @State private var renamingBin: MediaBin?
    @State private var isNamingNewBin = false
    /// What a new bin is to hold once it's named.
    @State private var newBinMedia = Set<MediaItem.ID>()
    @State private var binName = ""
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
            .sheet(isPresented: $isShowingRelink) {
                RelinkMediaView()
                    .environment(editor)
                    .environment(importer)
            }
            .alert("Library.Bin.NameTitle", isPresented: isNamingBin) {
                TextField("Library.Bin.Name", text: $binName)
                Button("Library.Bin.Save", action: saveBinName)
                Button("Relink.Cancel", role: .cancel) {}
            }
            .onChange(of: renamingBin) { _, bin in
                if let bin { binName = bin.name }
            }
            // A bin that's gone can't be looked in.
            .onChange(of: editor.project.bins) { _, bins in
                if case .bin(let id) = query.scope, !bins.contains(where: { $0.id == id }) { query.scope = .all }
            }
            #if os(iOS)
            .searchable(text: $query.search, prompt: Text("Library.Search"))
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
            VStack(spacing: 0) {
                LibraryFilterBar(query: $query, renamingBin: $renamingBin) { newBin(with: []) }
                    .padding(.horizontal, Self.gridPadding)
                    .padding(.vertical, 8)
                if !editor.missingMediaIDs.isEmpty {
                    missingBanner
                }
                Divider()
                if shownItems.isEmpty {
                    ContentUnavailableView {
                        Label("Library.NoResults.Title", systemImage: "magnifyingglass")
                    } description: {
                        Text("Library.NoResults.Message")
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    grid
                }
            }
        }
    }

    /// The media the bin, filters and search leave showing, in order.
    private var shownItems: [MediaItem] {
        query.items(in: editor.project)
    }

    /// Says some media's files can't be found, with the way to find them.
    private var missingBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(String(format: String(localized: "Library.Missing"), editor.missingMediaIDs.count))
                .font(.callout)
            Spacer(minLength: 0)
            Button("Library.Relink") { isShowingRelink = true }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, Self.gridPadding)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.12))
        .accessibilityElement(children: .combine)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.minimumCellWidth), spacing: 10)], spacing: 14) {
                let clipCounts = editor.project.clipCounts
                ForEach(shownItems) { item in
                    LibraryCell(
                        item: item, isSelected: selection.contains(item.id), clipCount: clipCounts[item.id] ?? 0,
                        isMissing: editor.missingMediaIDs.contains(item.id)
                    )
                        .contextMenu { itemMenu(ids(actingOn: item)) }
                        // Onto the timeline, or onto a bin to file it there.
                        .draggable(MediaDragPayload(mediaIDs: ordered(ids(actingOn: item))))
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
        .tracksMediaDrags(editor.timeline)
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
        let ids = shownItems.map(\.id)
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
            Menu("Library.MoveToBin", systemImage: "folder") {
                Button("Library.Bin.None") { editor.moveMedia(ids, toBin: nil) }
                ForEach(editor.project.bins) { bin in
                    Button(bin.name) { editor.moveMedia(ids, toBin: bin.id) }
                }
                Divider()
                Button("Library.Bin.NewWithSelection", systemImage: "folder.badge.plus") { newBin(with: ids) }
            }
            if !ids.isDisjoint(with: editor.missingMediaIDs) {
                Button("Library.Relink", systemImage: "link") { isShowingRelink = true }
            }
            Divider()
            Button("Library.Remove", systemImage: "trash", role: .destructive) { remove(ids) }
        }
    }

    /// The items in the order the project's library has them.
    private func ordered(_ ids: Set<MediaItem.ID>) -> [MediaItem.ID] {
        editor.project.media.map(\.id).filter(ids.contains)
    }

    /// Adds the items to the timeline in the order the library lists them.
    private func addToTimeline(_ ids: Set<MediaItem.ID>) {
        editor.addToTimeline(ordered(ids))
    }

    // MARK: - Bins

    private var isNamingBin: Binding<Bool> {
        Binding { isNamingNewBin || renamingBin != nil } set: { isShowing in
            guard !isShowing else { return }
            isNamingNewBin = false
            renamingBin = nil
        }
    }

    /// Asks for a name for a new bin, to file `ids` in.
    private func newBin(with ids: Set<MediaItem.ID>) {
        newBinMedia = ids
        binName = String(localized: "Library.Bin.DefaultName")
        isNamingNewBin = true
    }

    private func saveBinName() {
        let name = binName.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            isNamingNewBin = false
            renamingBin = nil
        }
        guard !name.isEmpty else { return }
        if let bin = renamingBin {
            editor.renameBin(bin.id, to: name)
        } else if isNamingNewBin {
            editor.addBin(named: name, filing: newBinMedia)
            newBinMedia = []
        }
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
    /// How many clips on the timeline are made from it.
    let clipCount: Int
    /// Whether its file can't be found.
    let isMissing: Bool

    static let cornerRadius: CGFloat = 10

    var body: some View {
        VStack(spacing: 5) {
            LibraryThumbnail(item: item)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(.rect(cornerRadius: Self.cornerRadius))
                .overlay(alignment: .bottomTrailing) { badge }
                .overlay(alignment: .topLeading) { status }
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

    /// Whether the file's missing, or else whether the timeline uses it.
    @ViewBuilder
    private var status: some View {
        if isMissing {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor)
                .font(.caption)
                .padding(4)
                .background(.black.opacity(0.6), in: .circle)
                .padding(4)
                .help(Text("Library.Status.Missing"))
        } else if clipCount > 0 {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(4)
                .background(.tint, in: .circle)
                .padding(4)
                .help(Text("Library.Status.Used"))
        }
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
        var parts = [kind]
        if item.kind != .image, let duration = Self.duration(of: item) {
            parts.append(duration.formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide)))
        }
        if isMissing {
            parts.append(String(localized: "Library.Status.Missing"))
        } else {
            parts.append(clipCount > 0 ? String(localized: "Library.Status.Used") : String(localized: "Library.Status.Unused"))
        }
        return parts.joined(separator: ", ")
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
            // Made again for a new size, or a new file once relinked.
            .task(id: LoadKey(size: pixelSize, location: item.location)) { await load() }
    }

    private struct LoadKey: Equatable {
        var size: CGSize
        var location: MediaLocation
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

private extension View {
    /// Keeps `isDraggingMedia` up to date while items are dragged out of the
    /// library, from when a drag is picked up to when it's put down. Drag
    /// sessions can only be followed from iOS 27.
    @ViewBuilder
    func tracksMediaDrags(_ timeline: TimelineState) -> some View {
        #if os(iOS)
        if #available(iOS 27, *) {
            onDragSessionUpdated { session in
                let isDragging = switch session.phase {
                case .initial, .active: true
                default: false
                }
                if timeline.isDraggingMedia != isDragging { timeline.isDraggingMedia = isDragging }
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
