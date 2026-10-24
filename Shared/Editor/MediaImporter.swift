import CoreTransferable
import Foundation
import MontageEngine
import MontageFormats
import Observation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Brings files into a project: reads what each one is, copies it into
/// staging to be saved into the package, and adds it to the library.
///
/// Imports run one batch after another, off the main actor. Each batch is
/// added to the library as one undo step when it's done; files that can't be
/// imported are collected in `failures` for the library to show.
@MainActor
@Observable
final class MediaImporter {
    /// How far the imports under way have got.
    struct Progress: Equatable {
        var completed: Int
        var total: Int
        /// The file being imported now.
        var currentName: String?
    }

    /// A file that couldn't be imported, and why.
    struct Failure: Identifiable, Equatable {
        let id = UUID()
        var name: String
        var message: String
    }

    /// Where a file to import comes from.
    enum Source: Sendable {
        /// A file the user chose, which may need security-scoped access.
        case file(URL)
        /// An item from the photo library, copied out as a file.
        case photo(PhotosPickerItem)
    }

    /// The kinds of file offered for import.
    static let importableTypes: [UTType] = [.movie, .audio, .image]

    /// Nil when nothing is being imported.
    private(set) var progress: Progress?
    /// Files that couldn't be imported, until they've been shown.
    var failures: [Failure] = []

    /// Where imported files are staged. Replaced if the document is.
    @ObservationIgnored var store: PackageMediaStore
    @ObservationIgnored private weak var editor: ProjectEditor?
    @ObservationIgnored private var queue: Task<Void, Never>?

    init(store: PackageMediaStore, editor: ProjectEditor) {
        self.store = store
        self.editor = editor
    }

    func importFiles(_ urls: [URL]) {
        enqueue(urls.map(Source.file))
    }

    func importPhotos(_ items: [PhotosPickerItem]) {
        enqueue(items.map(Source.photo))
    }

    func enqueue(_ sources: [Source]) {
        guard !sources.isEmpty else { return }
        var progress = self.progress ?? Progress(completed: 0, total: 0)
        progress.total += sources.count
        self.progress = progress

        let previous = queue
        queue = Task {
            await previous?.value
            await run(sources)
        }
    }

    private func run(_ sources: [Source]) async {
        var items: [MediaItem] = []
        for source in sources {
            progress?.currentName = source.displayName
            let store = self.store
            let taken = editor?.project.packageMediaPaths ?? []
            do {
                items.append(try await Self.prepare(source, store: store, takenPaths: taken))
            } catch {
                failures.append(Failure(name: source.displayName ?? "", message: Self.message(for: error)))
            }
            progress?.completed += 1
        }
        editor?.addMedia(items)
        if let progress, progress.completed >= progress.total {
            self.progress = nil
        }
    }

    /// Reads a file and stages it, off the main actor: both take a while for
    /// a long video.
    @concurrent
    private nonisolated static func prepare(
        _ source: Source, store: PackageMediaStore, takenPaths: Set<String>
    ) async throws -> MediaItem {
        switch source {
        case .file(let url):
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
            let probed = try await MediaProbe.probe(url)
            let path = try store.stage(copying: url, takenPaths: takenPaths)
            return item(named: url.lastPathComponent, probed, at: path)

        case .photo(let item):
            guard let file = try await item.loadTransferable(type: ReceivedMedia.self) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            // The received copy is the app's own: moved into staging, not copied.
            defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
            let probed = try await MediaProbe.probe(file.url)
            let name = file.url.lastPathComponent
            let path = try store.stage(moving: file.url, takenPaths: takenPaths)
            return Self.item(named: name, probed, at: path)
        }
    }

    private nonisolated static func item(named name: String, _ probed: ProbedMedia, at path: String) -> MediaItem {
        MediaItem(name: name, kind: probed.kind, location: .package(path: path), metadata: probed.metadata)
    }

    private static func message(for error: Error) -> String {
        let error = error as NSError
        return [error.localizedDescription, error.localizedRecoverySuggestion]
            .compactMap { $0 }.joined(separator: " ")
    }
}

extension MediaImporter.Source {
    var displayName: String? {
        switch self {
        case .file(let url): url.lastPathComponent
        case .photo: nil
        }
    }
}

/// A movie or image from the photo library, received as a file rather than
/// in memory, and copied somewhere the app can keep it before the system
/// takes the original away.
struct ReceivedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { try ReceivedMedia(copying: $0.file) }
        FileRepresentation(importedContentType: .image) { try ReceivedMedia(copying: $0.file) }
    }

    /// Copies into a folder of its own, so the file keeps its name.
    private init(copying file: URL) throws {
        let folder = URL.temporaryDirectory
            .appending(path: "Montage Received/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appending(path: file.lastPathComponent, directoryHint: .notDirectory)
        try FileManager.default.copyItem(at: file, to: url)
    }
}
