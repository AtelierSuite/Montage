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

    /// The library's thumbnails and the timeline's strips of frames, kept
    /// while the project is open, and in the package's cache behind that.
    @ObservationIgnored let thumbnails: ThumbnailCache
    /// The timeline's waveforms, kept the same way.
    @ObservationIgnored let waveforms: WaveformCache
    /// Where thumbnails and waveforms are kept on disk, if anywhere.
    @ObservationIgnored let cacheStore: (any MediaCacheStore)?

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

    private func apply(_ project: Project, undoName: String) {
        let previous = self.project
        self.project = project
        if let undoManager {
            undoManager.registerUndo(withTarget: self) { editor in
                MainActor.assumeIsolated { editor.apply(previous, undoName: undoName) }
            }
            undoManager.setActionName(undoName)
        }
        // As it is now: putting it in may have amended it.
        onChange(self.project)
    }
}
