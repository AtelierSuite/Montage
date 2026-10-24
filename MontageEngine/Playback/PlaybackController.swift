import AVFoundation
import Observation

/// Plays a project in the editor's preview, and follows its edits.
///
/// Wraps an `AVPlayer` whose item plays a `BuiltComposition` of the project.
/// When the project changes in a way that changes what plays, the composition
/// is built again off the main actor, a moment after the last change so a
/// drag doesn't rebuild on every step, and swapped in as a new player item at
/// the same time, still playing if it was. Every change goes straight into
/// `snapshot`, where whatever renders reads parameters that don't need a
/// rebuild.
///
/// One per open project. Call `invalidate()` when the project closes.
@MainActor
@Observable
public final class PlaybackController {
    /// The player to show in a player layer.
    public let player = AVPlayer()
    /// The project as of its latest edit, for the compositor and audio taps.
    public let snapshot: ProjectSnapshot

    /// The project as last handed in.
    public private(set) var project: Project
    /// What's playing: the composition built from the project, or nil before
    /// the first build is done.
    public private(set) var composition: BuiltComposition?
    /// Whether a build is waiting or running.
    public private(set) var isBuilding = false

    /// Where the playhead is.
    public private(set) var currentTime = CMTime.zero
    /// Whether playback is running, or is to run once a seek or rebuild is done.
    public private(set) var isPlaying = false
    /// How fast playback runs while it does: 1 forwards, faster when
    /// shuttled, and below zero backwards.
    public private(set) var rate: Float = 1
    /// Whether the playhead is being dragged.
    public private(set) var isScrubbing = false
    /// Why the player couldn't play the composition, if it couldn't. Cleared
    /// when the next one is swapped in.
    public private(set) var playbackError: (any Error)?

    /// How long the timeline runs.
    public var duration: CMTime { project.duration }
    /// The project's frame grid.
    public var frames: FrameTime { FrameTime(frameDuration: project.settings.frameDuration) }
    /// Whether there's anything to play.
    public var hasContent: Bool { !project.tracks.allSatisfy(\.clips.isEmpty) }

    @ObservationIgnored private var mediaResolver: MediaResolver
    /// How long after the last change a rebuild waits.
    @ObservationIgnored private let rebuildDelay: Duration
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var timeObserverInterval = CMTime.invalid
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var isInvalidated = false

    // Seeks are chased rather than queued: while one is under way, only the
    // latest time asked for is kept, and sought once it's done. Dragging the
    // playhead asks for many more times than the player can show.
    @ObservationIgnored private var pendingSeek: (time: CMTime, tolerance: CMTime)?
    @ObservationIgnored private var seekInFlight: Int?
    @ObservationIgnored private var seekCount = 0

    /// How far a seek may land from its time while the playhead is dragged,
    /// so the player can show the nearest frame it has rather than decode the
    /// exact one. Letting go seeks exactly.
    private static let scrubTolerance = CMTime(value: 1, timescale: 10)

    public init(project: Project, mediaResolver: MediaResolver, rebuildDelay: Duration = .milliseconds(150)) {
        self.project = project
        self.mediaResolver = mediaResolver
        self.rebuildDelay = rebuildDelay
        snapshot = ProjectSnapshot(project)
        player.actionAtItemEnd = .pause
        // Media is local, so there's no network to wait to buffer from.
        player.automaticallyWaitsToMinimizeStalling = false
        scheduleRebuild(after: .zero)
    }

    isolated deinit {
        tearDown()
    }

    /// Stops playback and lets go of the player's item. The controller
    /// does nothing more afterwards.
    public func invalidate() {
        tearDown()
    }

    // MARK: - Following edits

    /// Hands in the project after an edit. The snapshot takes it at once; the
    /// composition is rebuilt shortly unless the edit can't change it.
    public func update(project: Project, mediaResolver: MediaResolver) {
        snapshot.update(project)
        let previous = self.project
        self.project = project
        self.mediaResolver = mediaResolver
        // A resolver can't be compared, so a changed one always rebuilds:
        // the media it finds may be different.
        if Self.needsRebuild(from: previous, to: project) {
            scheduleRebuild(after: rebuildDelay)
        }
        if currentTime > duration { seek(to: duration) }
    }

    /// Hands in a new resolver, such as when the project has moved.
    public func update(mediaResolver: MediaResolver) {
        self.mediaResolver = mediaResolver
        scheduleRebuild(after: rebuildDelay)
    }

    /// Whether a change could change the composition. Conservative: anything
    /// but clip effects, which nothing renders yet and the compositor (#8)
    /// will read from the snapshot, rebuilds.
    nonisolated static func needsRebuild(from old: Project, to new: Project) -> Bool {
        func structure(_ project: Project) -> Project {
            var project = project
            for index in project.tracks.indices {
                for clip in project.tracks[index].clips where !clip.effects.isEmpty {
                    project.tracks[index].update(clip.id) { $0.effects = [] }
                }
            }
            return project
        }
        return old != new && structure(old) != structure(new)
    }

    private func scheduleRebuild(after delay: Duration) {
        guard !isInvalidated else { return }
        rebuildTask?.cancel()
        isBuilding = true
        rebuildTask = Task { [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            guard let builder = self.map({ CompositionBuilder(project: $0.project, mediaResolver: $0.mediaResolver) }) else { return }
            // Builds off the main actor; only cancelling throws.
            guard let built = try? await builder.build(), !Task.isCancelled else { return }
            self?.install(built)
        }
    }

    /// Swaps in a newly built composition where the old one was.
    private func install(_ built: BuiltComposition) {
        guard !isInvalidated else { return }
        rebuildTask = nil
        isBuilding = false
        composition = built
        let time = pendingSeek?.time ?? currentTime
        let item = built.makePlayerItem()
        playbackError = nil
        player.replaceCurrentItem(with: item)
        observeTime()
        observeEnd(of: item)
        observeStatus(of: item)
        // The old item's seeks are moot; start over at the same time.
        seekInFlight = nil
        pendingSeek = (min(time, duration), .zero)
        startNextSeek()
        if isPlaying { player.rate = rate }
    }

    // MARK: - Transport

    public func play() {
        guard hasContent, playbackError == nil else { return }
        // From the end, play from the start again.
        if let composition, currentTime >= min(duration, composition.duration) {
            seek(to: .zero)
        }
        isPlaying = true
        rate = 1
        player.play()
    }

    /// Plays at a rate, as J, K and L shuttle: 2 is twice as fast, -1 plays
    /// backwards, and 0 pauses. Forwards from the end starts again from the
    /// start; backwards stops at the start.
    public func shuttle(at rate: Float) {
        guard rate != 0 else { return pause() }
        guard hasContent, playbackError == nil else { return }
        if rate > 0, let composition, currentTime >= min(duration, composition.duration) {
            seek(to: .zero)
        }
        guard rate > 0 || currentTime > .zero else { return }
        isPlaying = true
        self.rate = rate
        player.rate = rate
    }

    public func pause() {
        isPlaying = false
        player.pause()
        // Where the player stopped, rather than where the last update said.
        if pendingSeek == nil, seekInFlight == nil, player.currentItem != nil {
            currentTime = clamped(player.currentTime())
        }
    }

    public func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Moves the playhead to exactly a time.
    public func seek(to time: CMTime) {
        chase(time, tolerance: .zero)
    }

    public func goToStart() {
        pause()
        seek(to: .zero)
    }

    public func goToEnd() {
        pause()
        seek(to: duration)
    }

    /// Pauses and moves the playhead one frame along the project's frame
    /// grid; a negative count steps back.
    public func step(by count: Int64) {
        pause()
        let frames = self.frames
        // From a time between frames, a step back lands on the frame showing.
        let frame = frames.frame(at: currentTime)
        let isOnFrame = frames.time(ofFrame: frame) == currentTime
        let target = count < 0 && !isOnFrame ? frame + count + 1 : frame + count
        seek(to: frames.time(ofFrame: max(0, target)))
    }

    // MARK: - Scrubbing

    /// Starts dragging the playhead: playback pauses, and resumes when the
    /// drag ends if it was running.
    public func beginScrubbing() {
        guard !isScrubbing else { return }
        isScrubbing = true
        wasPlayingBeforeScrub = isPlaying
        if isPlaying {
            player.pause()
            isPlaying = false
        }
    }

    /// Moves the playhead during a drag, showing a nearby frame quickly.
    public func scrub(to time: CMTime) {
        if !isScrubbing { beginScrubbing() }
        chase(time, tolerance: Self.scrubTolerance)
    }

    /// Ends the drag on the exact frame it was let go at.
    public func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        seek(to: pendingSeek?.time ?? currentTime)
        if wasPlayingBeforeScrub { play() }
    }

    @ObservationIgnored private var wasPlayingBeforeScrub = false

    // MARK: - Seeking

    private func chase(_ time: CMTime, tolerance: CMTime) {
        let time = clamped(time)
        currentTime = time
        pendingSeek = (time, tolerance)
        if seekInFlight == nil { startNextSeek() }
    }

    private func startNextSeek() {
        guard let (time, tolerance) = pendingSeek else { return }
        guard player.currentItem != nil else { return }
        pendingSeek = nil
        seekCount += 1
        let id = seekCount
        seekInFlight = id
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.seekInFlight == id else { return }
                self.seekInFlight = nil
                self.startNextSeek()
            }
        }
    }

    private func clamped(_ time: CMTime) -> CMTime {
        guard time.isNumeric else { return .zero }
        return max(.zero, min(time, duration))
    }

    // MARK: - Observing the player

    /// Follows the playhead about once a frame while playing.
    private func observeTime() {
        let interval = project.settings.frameDuration
        guard timeObserver == nil || interval != timeObserverInterval else { return }
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserverInterval = interval
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                self?.playerTimeChanged(time)
            }
        }
    }

    private func playerTimeChanged(_ time: CMTime) {
        // While seeking, the player reports where it's been, not where it's
        // going; the playhead already shows the target.
        guard pendingSeek == nil, seekInFlight == nil, !isScrubbing else { return }
        currentTime = clamped(time)
        // Played backwards to the start, the player stops without saying so.
        if isPlaying, rate < 0, currentTime <= .zero { pause() }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.currentTime = self.clamped(self.player.currentTime())
            }
        }
    }

    /// Notices the player giving up on an item, which it otherwise does
    /// silently: the playhead would sit still with the transport playing.
    private func observeStatus(of item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let error = item.error
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.playbackError = error ?? CocoaError(.featureUnsupported)
                self.isPlaying = false
            }
        }
    }

    private func tearDown() {
        isInvalidated = true
        rebuildTask?.cancel()
        rebuildTask = nil
        player.pause()
        isPlaying = false
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        statusObservation = nil
        player.replaceCurrentItem(with: nil)
    }
}
