import Foundation
import MontageEngine
import Observation

/// A project open for editing, shared by every view of it. Each platform's
/// document makes one, and hears about every change through `onChange` so it
/// can save.
///
/// Edits go through `perform`, which keeps the project as it was for undo:
/// the project is a value, so the snapshot is the undo step.
@MainActor
@Observable
final class ProjectEditor {
    private(set) var project: Project {
        didSet { playbackController?.update(project: project, mediaResolver: mediaResolver) }
    }
    /// Finds the media's files, wherever the project is kept.
    var mediaResolver: MediaResolver {
        didSet { playbackController?.update(mediaResolver: mediaResolver) }
    }

    /// Plays the project in the preview, following every change to it. Made
    /// the first time a view asks for it, so an editor that's never shown
    /// doesn't build anything; it goes when the editor does.
    var playback: PlaybackController {
        if let playbackController { return playbackController }
        let playbackController = PlaybackController(project: project, mediaResolver: mediaResolver)
        self.playbackController = playbackController
        return playbackController
    }
    @ObservationIgnored private var playbackController: PlaybackController?

    /// The library's thumbnails, kept while the project is open.
    @ObservationIgnored let thumbnails = ThumbnailCache()

    /// Where undo steps go: the document's undo manager.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Called after every change, with the project as it now is.
    @ObservationIgnored var onChange: (Project) -> Void = { _ in }

    init(project: Project, mediaResolver: MediaResolver = .none) {
        self.project = project
        self.mediaResolver = mediaResolver
    }

    /// Makes a change as one undo step, named for the Edit menu. A change
    /// that leaves the project as it was isn't recorded.
    func perform(_ actionName: String, _ change: (inout Project) -> Void) {
        var project = self.project
        change(&project)
        guard project != self.project else { return }
        apply(project, undoName: actionName)
    }

    /// Puts in a project read from outside, such as on revert, without an
    /// undo step: the history it would undo to is gone.
    func replace(with project: Project) {
        guard project != self.project else { return }
        self.project = project
    }

    /// Stops playback for good, when the project closes.
    func close() {
        playbackController?.invalidate()
    }

    private func apply(_ project: Project, undoName: String) {
        let previous = self.project
        self.project = project
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { editor in
                MainActor.assumeIsolated { editor.apply(previous, undoName: undoName) }
            }
            undoManager.setActionName(undoName)
        }
        onChange(project)
    }
}
