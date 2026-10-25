import CoreMedia
import MontageEngine
import SwiftUI

/// The timeline: a ruler over the project's tracks, each named in a header
/// down the leading edge, with the playhead across them all. The corner
/// above the headers shows where the playhead is, and dragging along the
/// ruler moves it.
///
/// The ruler and every clip are drawn in one canvas (`TimelineCanvas`), with
/// the gestures over it working out what's under them through
/// `TimelineLayout`:
/// - A tap or click selects a clip, or with `selectsMultiple`, Command or
///   Shift, adds it to the selection or takes it out. Elsewhere it clears
///   the selection.
/// - A long press then a drag moves clips, along their tracks and onto
///   others; on a Mac, a drag does.
/// - The handles at the ends of selected clips, and of the clip under the
///   pointer on a Mac, trim them, in the editor's trim style.
/// - Pinching zooms about where the pinch is.
/// - Media dragged from the library goes where it's dropped.
/// - With the timeline focused, keys edit: J, K and L shuttle, I and O mark
///   a range, M adds a marker, B splits, Delete deletes and Shift-Delete
///   ripple deletes, N turns snapping on and off, and + and - zoom.
///
/// Drags snap to the playhead, markers and clip edges, showing a line where
/// they've snapped.
struct TimelineView: View {
    @Environment(ProjectEditor.self) private var editor
    @Environment(\.displayScale) private var displayScale

    private let headerWidth = 88.0
    /// Room after the last clip, to see that it's the end.
    private let trailingRoom = 120.0
    /// The lanes' coordinate space, that every gesture's location is in.
    private static let space = "Timeline.Lanes"

    /// The size of the visible part of the lanes.
    @State private var viewport = CGSize.zero
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    /// How far the lanes are scrolled along.
    @State private var scrollOffset = 0.0
    @State private var drag: TimelineDrag?
    /// Whether a move or trim gesture is under way. It goes back to false
    /// however the gesture stops, including when the system cancels it
    /// without ending it, so the drag never outlives it.
    @GestureState private var isDragGestureActive = false
    /// The pinch under way: the zoom it began at, and the time and place in
    /// the view it's kept over.
    @State private var pinch: (pointsPerSecond: Double, time: Double, x: Double)?
    /// The clip under the pointer. Kept rather than the pointer's place, so
    /// the timeline is only redrawn when the pointer moves onto another clip.
    @State private var hoveredClip: Clip.ID?
    @State private var thumbnails: [MediaItem.ID: CGImage] = [:]
    @State private var waveforms: [MediaItem.ID: WaveformPeaks] = [:]
    /// The media each waveform was read for, so one is read again once its
    /// item is relinked to another file.
    @State private var waveformSources: [MediaItem.ID: MediaItem] = [:]
    /// Counts the long presses that picked clips up, for a tap of feedback.
    @State private var pickUps = 0
    @FocusState private var isFocused: Bool

    var body: some View {
        let layout = TimelineLayout(project: editor.project, pointsPerSecond: editor.timeline.pointsPerSecond)
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                headers(layout)
                ScrollView(.horizontal) {
                    lanes(layout)
                }
                .scrollPosition($scrollPosition)
                // A drag that moves clips or trims them doesn't scroll too.
                .scrollDisabled(drag != nil)
                .onScrollGeometryChange(for: Double.self) { $0.contentOffset.x } action: { scrollOffset = $1 }
                .background {
                    PlayheadFollower(
                        pointsPerSecond: layout.pointsPerSecond, visibleRange: scrollOffset...(scrollOffset + viewport.width),
                        isDragging: drag != nil, scrollPosition: $scrollPosition
                    )
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewport = CGSize(width: max(0, size.width - headerWidth), height: size.height)
        }
        .simultaneousGesture(pinching)
        .background(.background.secondary)
        #if os(macOS)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(phases: .down, action: keyPressed)
        #else
        // Focusing a view on iOS brings up the software keyboard, so a
        // hardware keyboard's keys come as shortcuts instead.
        .background { shortcuts }
        #endif
        .task(id: thumbnailRequests) { await loadThumbnails() }
        // Again once missing media turns up, to read the waveforms that
        // couldn't be read before.
        .task(id: WaveformRequests(media: waveformRequests, missing: editor.missingMediaIDs)) { await loadWaveforms() }
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .medium), trigger: pickUps)
        .sensoryFeedback(.alignment, trigger: drag?.snap?.point)
        #endif
    }

    /// As wide as the project runs, with room to spare.
    private func contentWidth(_ layout: TimelineLayout) -> Double {
        max(viewport.width, layout.x(editor.project.duration) + trailingRoom)
    }

    // MARK: - Headers

    private func headers(_ layout: TimelineLayout) -> some View {
        VStack(spacing: 0) {
            TimecodeLabel()
                .padding(.leading, 8)
                .frame(width: headerWidth, height: TimelineLayout.rulerHeight, alignment: .leading)
            Divider()
            ForEach(layout.rows) { row in
                header(row)
                    .frame(width: headerWidth, height: TimelineLayout.trackHeight - 1, alignment: .leading)
                Divider()
            }
        }
        // Held to its width: the dividers would otherwise take half the
        // timeline's.
        .frame(width: headerWidth)
    }

    private func header(_ row: TimelineLayout.Row) -> some View {
        Group {
            switch row.kind {
            case .video: Label("Timeline.Track.Video", systemImage: "film")
            case .audio: Label("Timeline.Track.Audio", systemImage: "waveform")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
    }

    // MARK: - Lanes

    private func lanes(_ layout: TimelineLayout) -> some View {
        let width = contentWidth(layout)
        let height = max(layout.height, viewport.height)
        // The canvas covers the part in sight and as much again either side,
        // so it's never caught short while it catches up with a scroll.
        let canvasWidth = min(width, max(viewport.width, 1) * 3)
        let origin = min(max(0, scrollOffset - viewport.width), width - canvasWidth)
        return ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: width, height: height)
                .contentShape(.rect)
                .onTapGesture(coordinateSpace: .named(Self.space)) { tapped(at: $0, layout: layout) }
                .gesture(moving(layout))
            TimelineCanvas(
                layout: layout, origin: origin, media: mediaByID, frames: editor.playback.frames,
                selected: editor.timeline.selectedClipIDs, hovered: hoveredClipID,
                markers: editor.project.markers, markedIn: editor.timeline.markedIn, markedOut: editor.timeline.markedOut,
                snapTime: drag?.snap?.point.time, thumbnails: thumbnails, waveforms: waveforms,
                showsEmptyMessage: editor.project.tracks.allSatisfy(\.clips.isEmpty), viewportWidth: viewport.width
            )
            .frame(width: canvasWidth, height: layout.height)
            .offset(x: origin)
            .allowsHitTesting(false)
            Color.clear
                .frame(width: width, height: TimelineLayout.rulerHeight)
                .contentShape(.rect)
                .gesture(scrubbing(layout))
            trimHandles(layout, visible: origin...(origin + canvasWidth))
            TimelineKeyframes(layout: layout, space: Self.space)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .overlay(alignment: .topLeading) {
            Playhead(pointsPerSecond: layout.pointsPerSecond)
        }
        .timelineMediaDrop(layout: layout) { ids, location in
            dropped(ids, at: location, layout: layout)
        }
        .coordinateSpace(.named(Self.space))
        .onChange(of: isDragGestureActive) { _, isActive in
            if !isActive { endDrag() }
        }
        .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
            switch phase {
            case .active(let location):
                let id = layout.clip(at: location)?.clip.id
                if id != hoveredClip { hoveredClip = id }
            case .ended:
                if hoveredClip != nil { hoveredClip = nil }
            }
        }
    }

    private var mediaByID: [MediaItem.ID: MediaItem] {
        Dictionary(editor.project.media.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The clip under the pointer, lit up, unless something's being dragged.
    private var hoveredClipID: Clip.ID? {
        drag == nil ? hoveredClip : nil
    }

    // MARK: - Selecting

    private func tapped(at location: CGPoint, layout: TimelineLayout) {
        focus()
        let extending = editor.timeline.selectsMultiple || Self.isExtendingSelection
        if let (clip, _) = layout.clip(at: location) {
            editor.select(clip.id, extending: extending)
        } else if !extending {
            editor.deselectAll()
        }
    }

    /// Whether Command or Shift is held, to add a clicked clip to the
    /// selection rather than select it alone.
    private static var isExtendingSelection: Bool {
        #if os(macOS)
        !NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
        #else
        false
        #endif
    }

    // MARK: - Moving

    /// Moves clips: after a long press on iOS, where a plain drag scrolls,
    /// and straight away on a Mac, which scrolls by trackpad or wheel.
    private func moving(_ layout: TimelineLayout) -> some Gesture {
        #if os(macOS)
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in moveChanged(start: value.startLocation, to: value.location, layout: layout) }
            .onEnded { _ in endDrag() }
        #else
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
            .onChanged { value in
                guard case .second(true, let value?) = value else { return }
                moveChanged(start: value.startLocation, to: value.location, layout: layout)
            }
            .onEnded { _ in endDrag() }
        #endif
    }

    private func moveChanged(start: CGPoint, to location: CGPoint, layout: TimelineLayout) {
        if drag == nil {
            focus()
            guard let move = TimelineDrag.move(at: start, layout: layout, editor: editor) else { return }
            drag = move
            pickUps += 1
        }
        drag?.update(to: location, editor: editor)
    }

    private func endDrag() {
        guard drag != nil else { return }
        drag = nil
        editor.endGesture()
    }

    // MARK: - Dropping

    /// Puts media dragged from the library where it's dropped: from the
    /// frame under it, on the track under it if that's of the media's kind
    /// and has room.
    private func dropped(_ ids: [MediaItem.ID], at location: CGPoint, layout: TimelineLayout) -> Bool {
        let ids = ids.filter { editor.project.mediaItem(id: $0) != nil }
        guard !ids.isEmpty else { return false }
        let target = layout.mediaDropTarget(at: location, frames: editor.playback.frames)
        focus()
        editor.insertMedia(ids, at: target.time, onTrack: target.trackID)
        return true
    }

    // MARK: - Trimming

    /// The edges that can be taken hold of to trim: those of the selected
    /// clips in sight, and of the clip under the pointer.
    private func trimHandles(_ layout: TimelineLayout, visible: ClosedRange<Double>) -> some View {
        let selected = editor.timeline.selectedClipIDs
        let hovered = hoveredClipID
        let clips = layout.clips(in: visible).filter { selected.contains($0.clip.id) || $0.clip.id == hovered }
        return ForEach(clips, id: \.clip.id) { clip, row in
            let rect = layout.rect(of: clip, inRow: row)
            trimHandle(clip.id, edge: .start, rect: rect, layout: layout)
            trimHandle(clip.id, edge: .end, rect: rect, layout: layout)
        }
    }

    #if os(macOS)
    /// How far a handle's hit area reaches outside the clip, and in.
    private let handleReach = (outside: 4.0, inside: 6.0)
    #else
    private let handleReach = (outside: 14.0, inside: 20.0)
    #endif

    private func trimHandle(_ id: Clip.ID, edge: ClipEdge, rect: CGRect, layout: TimelineLayout) -> some View {
        // Never more than a third of the clip inside it, so a short clip
        // can still be taken hold of in the middle to move.
        let inside = min(handleReach.inside, rect.width / 3)
        let width = handleReach.outside + inside
        let x = edge == .start ? rect.minX - handleReach.outside : rect.maxX - inside
        return Color.clear
            .frame(width: width, height: rect.height)
            .contentShape(.rect)
            #if os(macOS)
            .pointerStyle(.frameResize(position: edge == .start ? .leading : .trailing, directions: [.inward, .outward]))
            #endif
            .offset(x: x, y: rect.minY)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .updating($isDragGestureActive) { _, isActive, _ in isActive = true }
                    .onChanged { value in
                        if drag == nil {
                            focus()
                            if !editor.timeline.selectedClipIDs.contains(id) { editor.select(id) }
                            drag = TimelineDrag.trim(id, edge: edge, at: value.startLocation, layout: layout, editor: editor)
                        }
                        drag?.update(to: value.location, editor: editor)
                    }
                    .onEnded { _ in endDrag() }
            )
            .accessibilityHidden(true)
    }

    // MARK: - Scrubbing

    /// Tapping or dragging along the ruler moves the playhead there, onto
    /// the start of the frame under the finger.
    private func scrubbing(_ layout: TimelineLayout) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                let playback = editor.playback
                let time = CMTime(seconds: max(0, layout.seconds(atX: value.location.x)), preferredTimescale: 6000)
                playback.scrub(to: playback.frames.snapped(time))
            }
            .onEnded { _ in
                editor.playback.endScrubbing()
            }
    }

    // MARK: - Zooming

    /// Pinching zooms, keeping the time under the pinch where it is.
    private var pinching: some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let timeline = editor.timeline
                if pinch == nil {
                    let x = value.startLocation.x - headerWidth
                    pinch = (timeline.pointsPerSecond, (scrollOffset + x) / timeline.pointsPerSecond, x)
                }
                guard let pinch else { return }
                timeline.pointsPerSecond = pinch.pointsPerSecond
                timeline.zoom(by: value.magnification)
                scrollPosition.scrollTo(x: max(0, pinch.time * timeline.pointsPerSecond - pinch.x))
            }
            .onEnded { _ in pinch = nil }
    }

    /// Zooms by a factor about the playhead, keeping it where it is on
    /// screen, or in sight if it wasn't.
    private func zoom(by factor: Double) {
        let timeline = editor.timeline
        let time = editor.playback.currentTime.seconds
        let x = min(max(time * timeline.pointsPerSecond - scrollOffset, 0), viewport.width)
        timeline.zoom(by: factor)
        scrollPosition.scrollTo(x: max(0, time * timeline.pointsPerSecond - x))
    }

    /// Zooms so the whole project fits across.
    private func zoomToFit() {
        let duration = editor.project.duration.seconds
        guard duration > 0, viewport.width > 0 else { return }
        let timeline = editor.timeline
        timeline.pointsPerSecond = 1
        timeline.zoom(by: (viewport.width - trailingRoom / 2) / duration)
        scrollPosition.scrollTo(x: 0)
    }

    // MARK: - Keys

    /// Takes the keyboard's keys, on a Mac. On iOS they come as shortcuts,
    /// whatever has focus.
    private func focus() {
        #if os(macOS)
        isFocused = true
        #endif
    }

    #if os(iOS)
    /// The keys as buttons nobody sees, as `TransportShortcuts` does.
    private var shortcuts: some View {
        let keys: [(KeyEquivalent, EventModifiers)] = [
            ("j", []), ("k", []), ("l", []), ("i", []), ("o", []), ("x", []), ("m", []), ("b", []), ("n", []),
            ("=", []), ("-", []), ("z", .shift), ("a", .command), (.delete, []), (.delete, .shift), (.escape, []),
        ]
        return ZStack {
            ForEach(keys.indices, id: \.self) { index in
                let (key, modifiers) = keys[index]
                Button(String(key.character)) { _ = perform(key, modifiers: modifiers) }
                    .keyboardShortcut(key, modifiers: modifiers)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    #endif

    private func keyPressed(_ press: KeyPress) -> KeyPress.Result {
        perform(press.key, modifiers: press.modifiers.subtracting([.capsLock, .numericPad])) ? .handled : .ignored
    }

    /// Does what a key does, returning whether it did anything.
    private func perform(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        keyAction(key, modifiers: modifiers) == .handled
    }

    private func keyAction(_ key: KeyEquivalent, modifiers: EventModifiers) -> KeyPress.Result {
        let playback = editor.playback
        let timeline = editor.timeline
        let character = String(key.character).lowercased()
        if key == .delete || key == .deleteForward {
            guard editor.canDelete else { return .ignored }
            editor.deleteSelection(ripple: modifiers.contains(.shift))
            return .handled
        }
        if key == .escape {
            editor.deselectAll()
            return .handled
        }
        if modifiers == .command, character == "a" {
            editor.selectAllClips()
            return .handled
        }
        if modifiers == .shift, character == "z" {
            zoomToFit()
            return .handled
        }
        guard modifiers.isEmpty || modifiers == .shift else { return .ignored }
        switch character {
        case "j":
            // Again and again, faster backwards.
            playback.shuttle(at: playback.isPlaying && playback.rate < 0 ? max(playback.rate * 2, -8) : -1)
        case "k":
            playback.pause()
        case "l":
            playback.shuttle(at: playback.isPlaying && playback.rate > 0 ? min(playback.rate * 2, 8) : 1)
        case "i":
            editor.markIn()
        case "o":
            editor.markOut()
        case "x":
            editor.clearMarkedRange()
        case "m":
            editor.addMarkerAtPlayhead()
        case "b":
            editor.splitAtPlayhead()
        case "n":
            timeline.isSnapping.toggle()
        case "=", "+":
            zoom(by: 1.5)
        case "-":
            zoom(by: 1 / 1.5)
        default:
            return .ignored
        }
        return .handled
    }

    // MARK: - Thumbnails and waveforms

    /// The media whose pictures the video clips show, and the size, in
    /// pixels, to make them.
    private struct ThumbnailRequests: Equatable {
        var media: [MediaItem]
        var height: Double
    }

    private var thumbnailRequests: ThumbnailRequests {
        let onVideo = Set(editor.project.tracks.filter { $0.kind == .video }.flatMap(\.clips).map(\.mediaID))
        let media = editor.project.media.filter { onVideo.contains($0.id) && $0.kind != .audio }
        return ThumbnailRequests(
            media: media,
            height: ((TimelineLayout.trackHeight - TimelineLayout.laneInset * 2) * displayScale).rounded(.up)
        )
    }

    /// Makes each picture the clips need that hasn't been made, one at a
    /// time, through the editor's thumbnail cache.
    private func loadThumbnails() async {
        let requests = thumbnailRequests
        for item in requests.media where thumbnails[item.id] == nil {
            guard let url = editor.mediaResolver.url(for: item) else { continue }
            let size = item.metadata.presentationSize
            let aspect = size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
            let pixels = CGSize(width: (requests.height * aspect).rounded(.up), height: requests.height)
            let image = await editor.thumbnails.thumbnail(for: item, at: url, filling: pixels)
            guard !Task.isCancelled else { return }
            if let image { thumbnails[item.id] = image }
        }
    }

    private struct WaveformRequests: Equatable {
        var media: [MediaItem]
        var missing: Set<MediaItem.ID>
    }

    /// The media with sound whose clips show a waveform: those on audio
    /// tracks, and videos whose sound is still attached.
    private var waveformRequests: [MediaItem] {
        var heard = Set<MediaItem.ID>()
        for track in editor.project.tracks {
            for clip in track.clips where track.kind == .audio || !clip.isAudioDetached {
                if let mediaID = clip.mediaID { heard.insert(mediaID) }
            }
        }
        return editor.project.media.filter { heard.contains($0.id) && $0.kind != .image && $0.metadata.hasAudio }
    }

    /// Reads the sound of each media item the clips need that hasn't been
    /// read, one at a time, through the editor's waveform cache. The canvas
    /// draws them over audio clips, and along the bottom of video clips
    /// whose sound is still attached.
    private func loadWaveforms() async {
        for item in waveformRequests where waveformSources[item.id] != item {
            guard let url = editor.mediaResolver.url(for: item) else { continue }
            let peaks = await editor.waveforms.waveform(for: item, at: url)
            guard !Task.isCancelled else { return }
            // One that couldn't be read is tried again next time.
            guard let peaks else {
                waveforms[item.id] = nil
                waveformSources[item.id] = nil
                continue
            }
            waveformSources[item.id] = item
            waveforms[item.id] = peaks
        }
    }
}

/// Where the playhead is, as timecode. A view of its own, since it changes
/// every frame while playing and nothing else around it needs to.
private struct TimecodeLabel: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        let playback = editor.playback
        Text(verbatim: playback.frames.timecode(playback.currentTime))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

/// The line across the tracks at the playhead, with a grip at the top.
private struct Playhead: View {
    @Environment(ProjectEditor.self) private var editor
    let pointsPerSecond: Double

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .top) {
                UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(bottomLeading: 5, bottomTrailing: 5))
                    .fill(Color.accentColor)
                    .frame(width: 11, height: 10)
            }
            .offset(x: editor.playback.currentTime.seconds * pointsPerSecond - 0.75)
            .allowsHitTesting(false)
    }
}

/// Scrolls the lanes along to keep the playhead in sight: a page at a time
/// while playing, and straight to it when it's moved out of sight while
/// paused, such as by Go to End. Nothing to see; it only watches the time.
private struct PlayheadFollower: View {
    @Environment(ProjectEditor.self) private var editor
    let pointsPerSecond: Double
    let visibleRange: ClosedRange<Double>
    /// Whether clips are being dragged, which keeps the lanes still.
    let isDragging: Bool
    @Binding var scrollPosition: ScrollPosition

    var body: some View {
        Color.clear
            .onChange(of: editor.playback.currentTime) { _, time in
                let playback = editor.playback
                // Dragged along the ruler, the playhead is under the finger.
                guard !playback.isScrubbing, !isDragging, visibleRange.upperBound > visibleRange.lowerBound else { return }
                let x = time.seconds * pointsPerSecond
                let width = visibleRange.upperBound - visibleRange.lowerBound
                if playback.isPlaying {
                    // A page on when it reaches the edge, rather than
                    // following every frame, which would make the clips hard
                    // to watch.
                    let isReversed = playback.rate < 0
                    if x > visibleRange.upperBound - 8 || x < visibleRange.lowerBound {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            scrollPosition.scrollTo(x: max(0, isReversed ? x - width + 24 : x - 24))
                        }
                    }
                } else if x > visibleRange.upperBound - 4 || x < visibleRange.lowerBound {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrollPosition.scrollTo(x: max(0, x - width / 2))
                    }
                }
            }
    }
}
