import CoreMedia
import Foundation
import MontageEngine

/// A drag on the timeline under way: clips being moved, or a clip's edge
/// being trimmed. The whole drag is one gesture on the editor, so it's one
/// undo step, and each step remakes the change from where the drag began:
/// clips a moved clip passes over come back once it's gone by.
@MainActor
struct TimelineDrag {
    enum Action {
        /// Clips moving together, taken hold of by one of them, on a track
        /// of `kind` in `row`. `range` runs from the earliest start among
        /// them to the latest end.
        case move(ids: Set<Clip.ID>, kind: Track.Kind, row: Int, range: CMTimeRange)
        case trim(Clip.ID, ClipEdge)
    }

    let action: Action
    /// Where the drag began, in the lanes' space.
    let start: CGPoint
    /// The timeline as it was when the drag began.
    let layout: TimelineLayout
    let frames: FrameTime
    let snapper: TimelineSnapper
    /// Where the drag last snapped to, if it did.
    private(set) var snap: TimelineSnapper.Snap?

    #if os(macOS)
    /// How near, in points, a dragged edge has to come to a time to snap to it.
    static let snapDistance = 8.0
    #else
    static let snapDistance = 14.0
    #endif

    /// Starts moving the clip at a point, along with the rest of the
    /// selection if it's part of it, else selecting it alone. Nil if there's
    /// no clip there.
    static func move(at point: CGPoint, layout: TimelineLayout, editor: ProjectEditor) -> TimelineDrag? {
        guard let (clip, row) = layout.clip(at: point), let kind = layout.rows[row].track?.kind else { return nil }
        if !editor.timeline.selectedClipIDs.contains(clip.id) { editor.select(clip.id) }
        let ids = editor.selectedClipIDs
        let clips = editor.project.tracks.flatMap(\.clips).filter { ids.contains($0.id) }
        let start = clips.map(\.timelineStart).min() ?? clip.timelineStart
        let end = clips.map(\.timelineRange.end).max() ?? clip.timelineRange.end
        editor.beginGesture(String(localized: "Action.MoveClip"))
        return TimelineDrag(
            action: .move(ids: ids, kind: kind, row: row, range: CMTimeRange(start: start, end: end)),
            start: point, layout: layout, frames: editor.playback.frames,
            snapper: TimelineSnapper(project: editor.project, playhead: editor.playback.currentTime, excluding: ids)
        )
    }

    /// Starts trimming one edge of a clip.
    static func trim(_ id: Clip.ID, edge: ClipEdge, at point: CGPoint, layout: TimelineLayout, editor: ProjectEditor) -> TimelineDrag {
        editor.beginGesture(String(localized: "Action.TrimClip"))
        return TimelineDrag(
            action: .trim(id, edge), start: point, layout: layout, frames: editor.playback.frames,
            snapper: TimelineSnapper(project: editor.project, playhead: editor.playback.currentTime, excluding: [id])
        )
    }

    private init(action: Action, start: CGPoint, layout: TimelineLayout, frames: FrameTime, snapper: TimelineSnapper) {
        self.action = action
        self.start = start
        self.layout = layout
        self.frames = frames
        self.snapper = snapper
    }

    /// Follows the drag to a point, snapping if the editor's snapping is on.
    mutating func update(to point: CGPoint, editor: ProjectEditor) {
        let tolerance = CMTime(seconds: layout.seconds(atX: Self.snapDistance), preferredTimescale: 6000)
        let isSnapping = editor.timeline.isSnapping
        switch action {
        case let .move(ids, kind, row, range):
            var offset = frames.rounded(seconds: layout.seconds(atX: point.x - start.x))
            offset = max(offset, .zero - range.start)
            snap = isSnapping ? snapper.snap(CMTimeRange(start: range.start + offset, duration: range.duration), tolerance: tolerance) : nil
            if let snap { offset = max(offset + snap.adjustment, .zero - range.start) }
            // Video tracks are shown top layer first, so up is a layer on
            // for video, and a track back for audio.
            let target = layout.rowIndex(atY: point.y)
            let trackOffset = kind == .video ? row - target : target - row
            let delta = offset
            editor.updateGesture { $0.moveClips(ids, by: delta, trackOffsets: [kind: trackOffset]) }

        case let .trim(id, edge):
            var time = max(.zero, frames.rounded(seconds: layout.seconds(atX: point.x)))
            snap = isSnapping ? snapper.snap(time, tolerance: tolerance) : nil
            if let snap { time = snap.point.time }
            let style = editor.timeline.trimStyle
            let edgeTime = time
            editor.updateGesture { $0.trimClip(id, edge: edge, to: edgeTime, style: style) }
        }
    }
}
