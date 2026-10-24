import AppKit
import MontageEngine
import MontageFormats

/// A project open on the Mac: the project package it was read from.
@MainActor
final class ProjectDocument: NSDocument {
    /// The project as its window edits it. Its undo steps go to the
    /// document's undo manager, which is how the document knows it changed.
    let editor = ProjectEditor(project: Project())

    override init() {
        super.init()
        hasUndoManager = true
        editor.undoManager = undoManager
    }

    override class var autosavesInPlace: Bool { true }

    override func makeWindowControllers() {
        addWindowController(ProjectWindowController(editor: editor))
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
            // the package on disk are left where they are.
            let existing = fileURL.flatMap { try? FileWrapper(url: $0) }
            wrapper = try ProjectPackage.fileWrapper(for: editor.project, existing: existing)
        }
        guard let wrapper else { throw CocoaError(.fileWriteUnknown) }
        return wrapper
    }
}
