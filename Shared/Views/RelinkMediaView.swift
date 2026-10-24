import CoreMedia
import MontageEngine
import SwiftUI
import UniformTypeIdentifiers

/// The media whose files can't be found, and the way to find them again:
/// search a folder, or choose files, for ones with the same names, then
/// check each against what the media was like when it was imported before
/// relinking it. Each item can also be pointed at a file of the user's
/// choosing, one at a time.
///
/// Until it's relinked, missing media keeps its clips on the timeline, which
/// play as empty time.
struct RelinkMediaView: View {
    @Environment(ProjectEditor.self) private var editor
    @Environment(MediaImporter.self) private var importer
    @Environment(\.dismiss) private var dismiss

    /// What the file importer is choosing.
    private enum Picking {
        case folder, files
        case file(for: MediaItem.ID)
    }

    /// The file found for each item, waiting to be relinked.
    @State private var matches: [MediaItem.ID: MediaRelinker.Match] = [:]
    /// The items whose files will be relinked: those found, and confirmed or
    /// chosen by the user.
    @State private var included = Set<MediaItem.ID>()
    @State private var picking: Picking?
    @State private var isSearching = false
    @State private var isRelinking = false
    /// Set when a search found nothing for anything.
    @State private var foundNothing = false
    @State private var failures: [MediaImporter.Failure] = []
    /// Chosen folders and files, read from until the sheet closes.
    @State private var accessedURLs: [URL] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(editor.missingMedia) { item in
                        row(for: item)
                    }
                } footer: {
                    Text("Relink.Message")
                }
            }
            .overlay {
                if editor.missingMedia.isEmpty {
                    ContentUnavailableView("Relink.NoneMissing", systemImage: "checkmark.circle")
                }
            }
            .navigationTitle("Relink.Title")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(editor.missingMedia.isEmpty ? LocalizedStringKey("Relink.Done") : "Relink.Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Relink.Relink", action: relink)
                        .disabled(included.isEmpty || isRelinking)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { searchBar }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 420)
        #endif
        .fileImporter(
            isPresented: isPicking, allowedContentTypes: pickingTypes, allowsMultipleSelection: pickingMultiple
        ) { result in
            guard let picking, case .success(let urls) = result else { return }
            choose(urls, for: picking)
        }
        .alert("Relink.Failed.Title", isPresented: isShowingFailures, presenting: failures) { _ in
            Button("Library.ImportFailed.OK") { failures = [] }
        } message: { failures in
            Text(failures.map { "\($0.name): \($0.message)" }.joined(separator: "\n\n"))
        }
        .alert("Relink.NothingFound.Title", isPresented: $foundNothing) {
            Button("Library.ImportFailed.OK") {}
        } message: {
            Text("Relink.NothingFound.Message")
        }
        .onDisappear {
            for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
            accessedURLs = []
        }
    }

    // MARK: - Rows

    private func row(for item: MediaItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if matches[item.id] != nil {
                Button {
                    included.formSymmetricDifference([item.id])
                } label: {
                    Image(systemName: included.contains(item.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(included.contains(item.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .imageScale(.large)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Relink.Include"))
                .accessibilityValue(Text(included.contains(item.id) ? LocalizedStringKey("Relink.Included") : "Relink.NotIncluded"))
                .help(Text("Relink.Include"))
            } else {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.large)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Label(item.name, systemImage: Self.symbol(for: item.kind))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.summary(of: item.kind, item.metadata))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                status(for: item)
                    .font(.caption)
            }
            Spacer(minLength: 0)
            Button("Relink.Locate") { pick(.file(for: item.id)) }
                .disabled(isSearching || isRelinking)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func status(for item: MediaItem) -> some View {
        if let match = matches[item.id] {
            if match.isConfirmed {
                Label(String(format: String(localized: "Relink.Found"), match.url.lastPathComponent),
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            } else {
                Label(String(format: String(localized: "Relink.FoundDiffering"), match.url.lastPathComponent,
                             match.differences.map(Self.describe).joined(separator: "; ")),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        } else {
            Text("Relink.NotFound")
                .foregroundStyle(.secondary)
        }
    }

    private var searchBar: some View {
        HStack {
            Button("Relink.SearchFolder", systemImage: "folder") { pick(.folder) }
            Button("Relink.ChooseFiles", systemImage: "doc") { pick(.files) }
            Spacer()
            if isSearching || isRelinking {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Relink.CheckAgain") { editor.checkMedia() }
        }
        .disabled(isSearching || isRelinking || editor.missingMedia.isEmpty)
        .padding()
        .background(.bar)
    }

    // MARK: - Choosing files

    private var isPicking: Binding<Bool> {
        Binding { picking != nil } set: { if !$0 { picking = nil } }
    }

    private var pickingTypes: [UTType] {
        if case .folder = picking { [.folder] } else { MediaImporter.importableTypes }
    }

    private var pickingMultiple: Bool {
        if case .files = picking { true } else { false }
    }

    private func pick(_ what: Picking) {
        picking = what
    }

    private func choose(_ urls: [URL], for picking: Picking) {
        for url in urls where url.startAccessingSecurityScopedResource() {
            accessedURLs.append(url)
        }
        let missing = editor.missingMedia.filter { matches[$0.id] == nil || !matches[$0.id]!.isConfirmed }
        isSearching = true
        Task {
            defer { isSearching = false }
            switch picking {
            case .folder:
                guard let folder = urls.first else { return }
                let files = await Self.mediaFiles(in: folder)
                found(await MediaRelinker.match(missing, among: files), reportingNone: true)
            case .files:
                found(await MediaRelinker.match(missing, among: urls), reportingNone: true)
            case .file(let id):
                guard let url = urls.first, let item = editor.project.mediaItem(id: id) else { return }
                do {
                    let match = try await MediaRelinker.check(url, for: item)
                    matches[id] = match
                    // Chosen by hand, it's relinked whatever its differences.
                    included.insert(id)
                } catch {
                    failures.append(MediaImporter.Failure(name: url.lastPathComponent,
                                                          message: MediaImporter.message(for: error)))
                }
            }
        }
    }

    @concurrent
    private nonisolated static func mediaFiles(in folder: URL) async -> [URL] {
        MediaRelinker.mediaFiles(in: folder)
    }

    private func found(_ new: [MediaRelinker.Match], reportingNone: Bool) {
        for match in new {
            matches[match.mediaID] = match
            // Only files that are surely the same are relinked unasked.
            if match.isConfirmed { included.insert(match.mediaID) } else { included.remove(match.mediaID) }
        }
        if reportingNone, new.isEmpty { foundNothing = true }
    }

    // MARK: - Relinking

    private func relink() {
        let chosen = included.compactMap { matches[$0] }
        isRelinking = true
        Task {
            defer { isRelinking = false }
            failures = await importer.relink(chosen, in: editor)
            let missing = editor.missingMediaIDs
            matches = matches.filter { missing.contains($0.key) }
            included.formIntersection(missing)
            if missing.isEmpty, failures.isEmpty { dismiss() }
        }
    }

    private var isShowingFailures: Binding<Bool> {
        Binding { !failures.isEmpty } set: { if !$0 { failures = [] } }
    }

    // MARK: - Describing media

    static func symbol(for kind: MediaItem.Kind) -> String {
        switch kind {
        case .video: "film"
        case .audio: "waveform"
        case .image: "photo"
        }
    }

    /// What the media's like, such as "0:12 · 1920 × 1080 · 30 fps".
    static func summary(of kind: MediaItem.Kind, _ metadata: MediaMetadata) -> String {
        var parts: [String] = []
        if kind != .image { parts.append(duration(metadata.duration)) }
        if metadata.hasVideo { parts.append(size(metadata.presentationSize)) }
        if metadata.nominalFrameRate > 0 { parts.append(frameRate(metadata.nominalFrameRate)) }
        return parts.joined(separator: " · ")
    }

    private static func describe(_ difference: MediaRelinker.Difference) -> String {
        switch difference {
        case .kind:
            String(localized: "Relink.Difference.Kind")
        case .duration(let expected, let found):
            String(format: String(localized: "Relink.Difference.Duration"), duration(found), duration(expected))
        case .frameRate(let expected, let found):
            String(format: String(localized: "Relink.Difference.FrameRate"), frameRate(found), frameRate(expected))
        case .size(let expected, let found):
            String(format: String(localized: "Relink.Difference.Size"), size(found), size(expected))
        }
    }

    private static func duration(_ time: CMTime) -> String {
        let seconds = time.isNumeric ? max(time.seconds, 0) : 0
        let duration = Duration.milliseconds(Int64((seconds * 1000).rounded()))
        return duration.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond(padMinuteToLength: 1)))
    }

    private static func size(_ size: CGSize) -> String {
        "\(Int(size.width)) × \(Int(size.height))"
    }

    private static func frameRate(_ rate: Double) -> String {
        String(format: String(localized: "Relink.FrameRate"), rate.formatted(.number.precision(.fractionLength(0...2))))
    }
}
