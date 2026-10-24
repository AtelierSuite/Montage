import CoreMedia
import MontageEngine
import Observation

/// What the timeline is showing and how it edits, kept with the editor so
/// the inspector, the menus and the toolbars all see the same: above all,
/// which clips are selected.
///
/// None of it is part of the project, so none of it is undone or saved.
@MainActor
@Observable
final class TimelineState {
    /// The clips selected on the timeline, for the inspector and the edit
    /// commands to act on. IDs of clips since taken off the timeline can
    /// linger; `ProjectEditor.selectedClipIDs` leaves them out.
    var selectedClipIDs: Set<Clip.ID> = []
    /// Whether tapping a clip adds it to the selection, or takes it out,
    /// rather than selecting it alone. A modifier key does the same on a Mac.
    var selectsMultiple = false
    /// Whether drags snap to the playhead, markers and clip edges.
    var isSnapping = true
    /// How dragging a clip's edge treats the clips after it.
    var trimStyle = TrimStyle.trim
    /// How far apart, in points, the timeline draws each second.
    var pointsPerSecond = 60.0
    /// The range marked with I and O, for playing or acting on a part of
    /// the timeline. Either end can be marked without the other.
    var markedIn: CMTime?
    var markedOut: CMTime?
    /// Whether media from the library is being dragged, for the editor to
    /// give the timeline room to take it.
    var isDraggingMedia = false

    /// How far the timeline zooms in and out.
    static let zoomRange = 2.0...2400.0

    /// Zooms in (above 1) or out (below 1) by a factor.
    func zoom(by factor: Double) {
        pointsPerSecond = min(max(pointsPerSecond * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }
}
