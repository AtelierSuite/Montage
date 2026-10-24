import Foundation
import MontageEngine
import Observation

/// A project open for editing, shared by every view of it. Each platform's
/// document makes one, and hears about every change through `onChange` so it
/// can save.
///
/// Edits go through `perform`, which keeps the project as it was for undo:
/// the project is a value, so the snapshot is the undo step. A continuous
/// gesture, such as dragging a clip or a slider, is one undo step however
/// many changes it makes: `beginGesture`, then `updateGesture` as it goes,
/// then `endGesture`.
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

    /// The gesture under way: the project as it was when it began, and the
    /// name of the undo step it makes.
    @ObservationIgnored private var gesture: (baseline: Project, actionName: String)?

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
        if gesture != nil { endGesture() }
        var project = self.project
        change(&project)
        guard project != self.project else { return }
        apply(project, undoName: actionName)
    }

    // MARK: - Gestures

    /// The project as it was when the gesture under way began, or nil when
    /// there's none.
    var gestureBaseline: Project? { gesture?.baseline }

    /// Starts a continuous change, such as a drag, that ends as one undo
    /// step with the given name.
    func beginGesture(_ actionName: String) {
        if gesture != nil { endGesture() }
        gesture = (project, actionName)
    }

    /// Changes the project during a gesture. Each change starts again from
    /// the project as it was when the gesture began, so a drag can make the
    /// whole of its change from where it started, every step of the way.
    func updateGesture(_ change: (inout Project) -> Void) {
        guard let gesture else { return }
        var project = gesture.baseline
        change(&project)
        if project != self.project { self.project = project }
    }

    /// Ends the gesture as one undo step, unless it left the project as it
    /// was.
    func endGesture() {
        guard let gesture else { return }
        self.gesture = nil
        guard project != gesture.baseline else { return }
        apply(project, undoName: gesture.actionName, from: gesture.baseline)
    }

    /// Ends the gesture, putting the project back as it was.
    func cancelGesture() {
        guard let gesture else { return }
        self.gesture = nil
        if project != gesture.baseline { project = gesture.baseline }
    }

    /// Puts in a project read from outside, such as on revert, without an
    /// undo step: the history it would undo to is gone.
    func replace(with project: Project) {
        gesture = nil
        guard project != self.project else { return }
        self.project = project
    }

    /// Stops playback for good, when the project closes.
    func close() {
        playbackController?.invalidate()
    }

    /// Puts in a changed project, undone back to `previous`: the project as
    /// it is unless a gesture has already put the change in.
    private func apply(_ project: Project, undoName: String, from previous: Project? = nil) {
        let previous = previous ?? self.project
        if project != self.project { self.project = project }
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { editor in
                MainActor.assumeIsolated { editor.apply(previous, undoName: undoName) }
            }
            undoManager.setActionName(undoName)
        }
        onChange(project)
    }
}
