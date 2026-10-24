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
        didSet {
            playbackController?.update(project: project, mediaResolver: mediaResolver)
            if project.media != oldValue.media { checkMedia() }
        }
    }
    /// Finds the media's files, wherever the project is kept.
    var mediaResolver: MediaResolver {
        didSet {
            playbackController?.update(mediaResolver: mediaResolver)
            checkMedia()
        }
    }
    /// The media whose files can't be found, as of the last `checkMedia()`,
    /// which is what sets it. Their clips stay on the timeline, and play as
    /// empty time, until the media is relinked.
    var missingMediaIDs: Set<MediaItem.ID> = []

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

    /// The timeline's selection, zoom and editing options.
    let timeline = TimelineState()

    /// The library's thumbnails and the timeline's strips of frames, kept
    /// while the project is open, and in the package's cache behind that.
    @ObservationIgnored let thumbnails: ThumbnailCache
    /// The timeline's waveforms, kept the same way.
    @ObservationIgnored let waveforms: WaveformCache
    /// Where thumbnails and waveforms are kept on disk, if anywhere.
    @ObservationIgnored let cacheStore: (any MediaCacheStore)?

    /// The gesture under way: the project as it was when it began, and the
    /// name of the undo step it makes.
    @ObservationIgnored private var gesture: (baseline: Project, actionName: String)?

    /// Where undo steps go: the document's undo manager.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// Called after every change, with the project as it now is.
    @ObservationIgnored var onChange: (Project) -> Void = { _ in }
    /// Called after a change that isn't an undo step, as when stale
    /// bookmarks are made again, for the document to know to save it.
    @ObservationIgnored var onAmend: () -> Void = {}
    /// Fresh bookmarks made, since last asked, for media found through stale
    /// ones, by the stale bookmark: the document's media store's.
    @ObservationIgnored var takeRefreshedBookmarks: () -> [Data: Data] = { [:] }

    /// `cache` is where thumbnails and waveforms are kept on disk, if
    /// anywhere: the project package's cache folder.
    init(project: Project, mediaResolver: MediaResolver = .none, cache: (any MediaCacheStore)? = nil) {
        self.project = project
        self.mediaResolver = mediaResolver
        thumbnails = ThumbnailCache(store: cache, capacity: 600)
        waveforms = WaveformCache(store: cache)
        cacheStore = cache
        checkMedia()
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

    /// The name of the gesture under way, or nil when there's none.
    var gestureActionName: String? { gesture?.actionName }

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

    /// Makes a change that isn't an undo step: one the user didn't make, and
    /// that undoing their own changes shouldn't take back.
    func amend(_ change: (inout Project) -> Void) {
        var project = self.project
        change(&project)
        guard project != self.project else { return }
        self.project = project
        onChange(project)
        onAmend()
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
                MainActor.assumeIsolated {
                    // Undone mid-drag, the drag lets go of its change rather
                    // than putting it back over the undo when it ends.
                    editor.cancelGesture()
                    editor.apply(previous, undoName: undoName)
                }
            }
            undoManager.setActionName(undoName)
        }
        // As it is now: putting it in may have amended it.
        onChange(self.project)
    }
}
