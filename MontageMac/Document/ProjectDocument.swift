import AppKit
import MontageEngine
import MontageFormats

/// A project open on the Mac: the project package it was read from.
@MainActor
final class ProjectDocument: NSDocument {
    /// The project as its window edits it. Its undo steps go to the
    /// document's undo manager, which is how the document knows it changed.
    let editor: ProjectEditor
    /// The media imported into the project but not saved yet, and where the
    /// package is, so the editor finds media before and after it's saved.
    let media = PackageMediaStore()
    /// Thumbnails and waveforms, kept in the package's cache folder.
    let cache: PackageCache
    /// Brings files into the project, staged in `media` until it's saved.
    private(set) lazy var importer = MediaImporter(store: media, editor: editor)

    override init() {
        let cache = PackageCache()
        self.cache = cache
        editor = ProjectEditor(project: Project(), cache: cache)
        super.init()
        hasUndoManager = true
        editor.undoManager = undoManager
        editor.mediaResolver = media.resolver
    }

    // Set when the document is opened, first saved, renamed or moved.
    override var fileURL: URL? {
        didSet {
            media.packageURL = fileURL
            cache.packageURL = fileURL
        }
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(ProjectWindowController(editor: editor, importer: importer))
    }

    override func close() {
        editor.close()
        super.close()
    }

    // MARK: - Reading and writing

    // Documents are read and written on the main thread: neither
    // `canConcurrentlyReadDocuments` nor `canAsynchronouslyWrite` is on.

    override nonisolated func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let project = try ProjectPackage.read(fileWrapper)
        MainActor.assumeIsolated { editor.replace(with: project) }
    }

    override nonisolated func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        // A file wrapper isn't Sendable, so it is handed out of the main
        // actor's closure by hand; it never leaves the main thread.
        nonisolated(unsafe) var wrapper: FileWrapper?
        try MainActor.assumeIsolated {
            // Only the project is written again: media and caches already in
            // the package on disk are left where they are. An untitled
            // project has only been autosaved, but its media is there too.
            let existing = (fileURL ?? autosavedContentsFileURL).flatMap { try? FileWrapper(url: $0) }
            wrapper = try ProjectPackage.fileWrapper(for: editor.project, existing: existing, media: media)
        }
        guard let wrapper else { throw CocoaError(.fileWriteUnknown) }
        return wrapper
    }
}
