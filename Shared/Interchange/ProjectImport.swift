import Foundation
import MontageEngine
import MontageFormats
import Observation
import UniformTypeIdentifiers

/// Brings another editor's project into an open one: reads the file, finds
/// and copies in the media it uses, and puts the result in place of the
/// project, as one undo step. Media that isn't found stays in the library,
/// its file missing, for the user to relink.
///
/// Afterwards `report` holds what didn't come across, for the window to show.
@MainActor
@Observable
final class ProjectImport {
    /// Whether a project is being read or its media copied in.
    private(set) var isImporting = false
    /// What the last import couldn't bring across, until it's been shown.
    var report: ImportReport?
    /// Why the last import failed, until it's been shown.
    var failure: String?

    /// The kinds of file a project can be imported from.
    static var importableTypes: [UTType] { ProjectInterchange.importableTypes }

    /// Called when an import has finished, well or not.
    @ObservationIgnored var onFinish: () -> Void = {}

    @ObservationIgnored private weak var editor: ProjectEditor?
    @ObservationIgnored private let store: () -> PackageMediaStore

    /// `store` is where the media is staged: the document's, whichever that
    /// is at the time.
    init(editor: ProjectEditor, store: @escaping () -> PackageMediaStore) {
        self.editor = editor
        self.store = store
    }

    func start(_ url: URL) {
        guard !isImporting, let editor else { return }
        isImporting = true
        let store = store()
        // Clear of the project's media, which undo brings back, and of
        // whatever else is in its package.
        var taken = editor.project.packageMediaPaths
        if let packageURL = store.packageURL {
            let folder = packageURL.appending(path: ProjectPackage.mediaDirectoryName, directoryHint: .isDirectory)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            taken.formUnion(names.map(ProjectPackage.mediaPath(forFileName:)))
        }
        let takenPaths = taken
        Task {
            defer {
                isImporting = false
                onFinish()
            }
            do {
                let imported = try await Self.read(url, store: store, takenPaths: takenPaths)
                editor.replaceContents(with: imported.project)
                report = imported.report
            } catch {
                let error = error as NSError
                failure = [error.localizedDescription, error.localizedRecoverySuggestion].compactMap { $0 }
                    .joined(separator: " ")
            }
        }
    }

    /// Reads the file and gathers its media, off the main actor: copying in
    /// a project's worth of video takes a while.
    @concurrent
    private nonisolated static func read(_ url: URL, store: PackageMediaStore, takenPaths: Set<String>) async throws -> ImportedProject {
        let isAccessing = url.startAccessingSecurityScopedResource()
        defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
        let imported = try ProjectInterchange.read(contentsOf: url)
        // Media is looked for beside the file, and inside it if it's a bundle.
        var folders = [url.deletingLastPathComponent()]
        if url.hasDirectoryPath { folders.insert(url, at: 0) }
        return await ProjectInterchange.gatherMedia(for: imported, into: store, takenPaths: takenPaths, searchFolders: folders)
    }
}
