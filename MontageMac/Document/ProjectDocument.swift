import AppKit
import MontageEngine
import MontageFormats
import Synchronization

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
        editor.takeRefreshedBookmarks = { [media] in media.bookmarks.takeRefreshedBookmarks() }
        // Changes that aren't undo steps still need saving.
        editor.onAmend = { [weak self] in self?.updateChangeCount(.changeDone) }
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

    // Documents are read on the main thread: `canConcurrentlyReadDocuments`
    // isn't on. They're written on another thread, from a snapshot taken on
    // the main thread when the save begins, so saving a project, and the
    // first save of a project with long videos imported into it, which
    // copies them into the package, doesn't hold up editing.

    /// What a save writes: the project as it was when the save began, and
    /// the package on disk that its media and caches are kept from.
    private struct SaveSnapshot: Sendable {
        var project: Project
        var existingURL: URL?
    }

    /// The snapshot of the latest save, for the thread that writes it.
    private nonisolated let saveSnapshot = Mutex<SaveSnapshot?>(nil)

    override func save(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        // An untitled project has only been autosaved, but its media is
        // there too.
        let snapshot = SaveSnapshot(project: editor.project, existingURL: fileURL ?? autosavedContentsFileURL)
        saveSnapshot.withLock { $0 = snapshot }
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    override func canAsynchronouslyWrite(
        to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        true
    }

    override nonisolated func read(from fileWrapper: FileWrapper, ofType typeName: String) throws {
        let project = try ProjectPackage.read(fileWrapper)
        MainActor.assumeIsolated { editor.replace(with: project) }
    }

    override nonisolated func fileWrapper(ofType typeName: String) throws -> FileWrapper {
        let snapshot: SaveSnapshot
        if Thread.isMainThread {
            // Written on the main thread, as when duplicating, the project
            // is read as it is now.
            snapshot = MainActor.assumeIsolated {
                SaveSnapshot(project: editor.project, existingURL: fileURL ?? autosavedContentsFileURL)
            }
        } else {
            // On the writing thread, while the main thread waits for the
            // snapshot to be taken; the save took it as it began.
            guard let saved = saveSnapshot.withLock({ $0 }) else { throw CocoaError(.fileWriteUnknown) }
            snapshot = saved
        }
        // Only the project is written again: media and caches already in
        // the package on disk are left where they are.
        let existing = snapshot.existingURL.flatMap { try? FileWrapper(url: $0) }
        // NSDocument lets the main thread go on once this returns, and writes
        // the wrapper here, copying in staged media as it goes.
        return try ProjectPackage.fileWrapper(for: snapshot.project, existing: existing, media: media)
    }
}
