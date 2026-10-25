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
            playbackController?.update(project: project, mediaResolver: playbackResolver)
            if project.media != oldValue.media {
                checkMedia()
                removeCopies(ofMediaRemovedFrom: oldValue)
            }
            // Not on every step of a drag: once it ends.
            if gesture == nil { makeDerivedMedia() }
        }
    }
    /// Finds the media's files, wherever the project is kept.
    var mediaResolver: MediaResolver {
        didSet {
            playbackController?.update(mediaResolver: playbackResolver)
            checkMedia()
            makeDerivedMedia()
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
        let playbackController = PlaybackController(project: project, mediaResolver: playbackResolver)
        playbackController.usesProxies = usesProxies
        self.playbackController = playbackController
        return playbackController
    }
    @ObservationIgnored private(set) var playbackController: PlaybackController?

    /// Whether preview plays large video from smaller copies, made in the
    /// background. Export always uses the originals. The same for every
    /// open project, and kept for next time.
    var usesProxies: Bool {
        get { PreviewSettings.shared.usesProxies }
        set { PreviewSettings.shared.usesProxies = newValue }
    }

    /// Follows a change to `usesProxies`, made here or in another project.
    func previewSettingsChanged() {
        playbackController?.usesProxies = usesProxies
        // Turned off, proxies stop being made.
        if !usesProxies { stopMakingDerivedMedia(.proxy) }
        makeDerivedMedia()
    }

    /// The timeline's selection, zoom and editing options.
    let timeline = TimelineState()

    /// The library's thumbnails and the timeline's strips of frames, kept
    /// while the project is open, and in the package's cache behind that.
    @ObservationIgnored let thumbnails: ThumbnailCache
    /// The timeline's waveforms, kept the same way.
    @ObservationIgnored let waveforms: WaveformCache
    /// Where thumbnails and waveforms are kept on disk, if anywhere.
    @ObservationIgnored let cacheStore: (any MediaCacheStore)?
    /// Makes the copies of media the composition plays in their place, into
    /// the same cache.
    @ObservationIgnored let derivedMedia: DerivedMediaCache
    /// The copies being made, a task for each kind so a quick stereo copy
    /// doesn't wait behind a proxy, and the kinds asked for again meanwhile.
    @ObservationIgnored var derivedMediaTasks: [DerivedMedia: (id: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored var pendingDerivedMedia: Set<DerivedMedia> = []
    /// The copies known to be there, or known not to be made, by kind and
    /// file name, so edits don't look for them on disk again.
    @ObservationIgnored var settledDerivedMedia: Set<String> = []

    @ObservationIgnored private var settingsObserver: (any NSObjectProtocol)?

    /// The gesture under way: the project as it was when it began, and the
    /// name of the undo step it makes.
    @ObservationIgnored private var gesture: (baseline: Project, actionName: String)?

    /// The control whose changes the last undo step was made of, and when
    /// it last changed, for `coalescingChanges` to add more to it.
    @ObservationIgnored private var lastCoalescedStep: (key: AnyHashable, actionName: String, date: Date)?
    /// The control whose changes `perform` is making, inside
    /// `coalescingChanges`.
    @ObservationIgnored private var coalescingKey: AnyHashable?

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
        derivedMedia = DerivedMediaCache(store: cache as? any DerivedMediaStore)
        checkMedia()
        makeDerivedMedia()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: PreviewSettings.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.previewSettingsChanged() }
        }
    }

    /// Makes a change as one undo step, named for the Edit menu. A change
    /// that leaves the project as it was isn't recorded.
    func perform(_ actionName: String, _ change: (inout Project) -> Void) {
        if gesture != nil { endGesture() }
        var project = self.project
        change(&project)
        guard project != self.project else { return }
        if let coalescingKey {
            let now = Date()
            if let last = lastCoalescedStep, last.key == coalescingKey, last.actionName == actionName,
               now.timeIntervalSince(last.date) < Self.coalescingInterval {
                // Its undo step already goes back to before the first of
                // them.
                self.project = project
                onChange(self.project)
            } else {
                apply(project, undoName: actionName)
            }
            lastCoalescedStep = (coalescingKey, actionName, now)
        } else {
            apply(project, undoName: actionName)
        }
    }

    // MARK: - Coalescing

    /// How soon after a control's last change another from it joins the
    /// same undo step.
    static let coalescingInterval: TimeInterval = 1

    /// Makes the changes `body` performs join the last undo step, when that
    /// was made of the same control's changes a moment ago and nothing's
    /// been done since: for a control that changes the project over and
    /// over without saying when it's let go, such as a colour well, whose
    /// colour panel changes the colour all the while it's dragged in. Each
    /// change is in the project, and saved, at once, unlike a gesture's.
    func coalescingChanges(_ key: AnyHashable, _ body: () -> Void) {
        let outer = coalescingKey
        coalescingKey = key
        defer { coalescingKey = outer }
        body()
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
        defer { makeDerivedMedia() }
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
        lastCoalescedStep = nil
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
        stopMakingDerivedMedia()
        if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) }
        settingsObserver = nil
    }

    /// Puts in a changed project, undone back to `previous`: the project as
    /// it is unless a gesture has already put the change in.
    private func apply(_ project: Project, undoName: String, from previous: Project? = nil) {
        let previous = previous ?? self.project
        // Another step, or an undo or redo, so nothing more joins the last.
        lastCoalescedStep = nil
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
