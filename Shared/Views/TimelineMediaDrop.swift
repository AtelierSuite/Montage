import CoreMedia
import MontageEngine
import SwiftUI
import UniformTypeIdentifiers

extension TimelineLayout {
    /// Where media dropped at a point in the lanes goes: from the frame
    /// under it, on the track under it, if any.
    func mediaDropTarget(at location: CGPoint, frames: FrameTime) -> (time: CMTime, trackID: Track.ID?) {
        let time = max(.zero, frames.rounded(seconds: seconds(atX: location.x)))
        let row = rowIndex(atY: location.y)
        return (time, rows.indices.contains(row) ? rows[row].track?.id : nil)
    }
}

extension View {
    /// Takes media dragged from the library onto the timeline's lanes,
    /// showing where its clips will go while it's held over them. `onDrop`
    /// gets the items and where they were let go.
    func timelineMediaDrop(layout: TimelineLayout, onDrop: @escaping ([MediaItem.ID], CGPoint) -> Bool) -> some View {
        modifier(TimelineMediaDrop(layout: layout, onDrop: onDrop))
    }
}

/// Where a drop held over the timeline would put its clips.
private struct MediaDropPreview: Equatable {
    var time: CMTime
    var trackID: Track.ID?
    var placements: [ClipPlacement]
}

private struct TimelineMediaDrop: ViewModifier {
    let layout: TimelineLayout
    let onDrop: ([MediaItem.ID], CGPoint) -> Bool
    @Environment(ProjectEditor.self) private var editor
    @State private var preview: MediaDropPreview?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                if let preview {
                    MediaDropIndicator(preview: preview, layout: layout)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(
                of: [.montageMediaReference],
                delegate: MediaDropDelegate(layout: layout, editor: editor, preview: $preview, onDrop: onDrop)
            )
    }
}

private struct MediaDropDelegate: DropDelegate {
    let layout: TimelineLayout
    let editor: ProjectEditor
    @Binding var preview: MediaDropPreview?
    let onDrop: ([MediaItem.ID], CGPoint) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.montageMediaReference])
    }

    func dropEntered(info: DropInfo) {
        update(at: info.location)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(at: info.location)
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        preview = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        preview = nil
        let providers = info.itemProviders(for: [.montageMediaReference])
        guard !providers.isEmpty else { return false }
        let location = info.location
        let onDrop = onDrop
        let timeline = editor.timeline
        Task { @MainActor in
            var ids: [MediaItem.ID] = []
            for provider in providers {
                if let payload = await Self.payload(from: provider) { ids += payload.mediaIDs }
            }
            timeline.draggedMediaIDs = []
            _ = onDrop(ids, location)
        }
        return true
    }

    /// Works out where the drop would go, if it's moved to another frame or
    /// track. The items come from the library, which says what it's
    /// dragging; a drop's own items can only be read once it's let go.
    private func update(at location: CGPoint) {
        let target = layout.mediaDropTarget(at: location, frames: editor.playback.frames)
        guard preview?.time != target.time || preview?.trackID != target.trackID else { return }
        let ids = editor.timeline.draggedMediaIDs
        preview = MediaDropPreview(
            time: target.time, trackID: target.trackID,
            placements: editor.project.placements(ofClipsOf: ids, at: target.time, onTrack: target.trackID)
        )
    }

    private static func payload(from provider: NSItemProvider) async -> MediaDragPayload? {
        await withCheckedContinuation { continuation in
            _ = provider.loadTransferable(type: MediaDragPayload.self) { result in
                continuation.resume(returning: try? result.get())
            }
        }
    }
}

/// Shows where a drop will go: a line at the time it starts from, and the
/// space each clip will take. A clip that goes on a new track is shown as a
/// bar along the edge the track will be added at.
private struct MediaDropIndicator: View {
    let preview: MediaDropPreview
    let layout: TimelineLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(preview.placements.enumerated()), id: \.offset) { _, placement in
                let rect = rect(for: placement)
                if placement.isNewTrack && row(for: placement) == nil {
                    Capsule()
                        .fill(.tint)
                        .frame(width: max(rect.width, 4), height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.tint.opacity(0.25))
                        .strokeBorder(.tint, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .frame(width: max(rect.width, 4), height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            Rectangle()
                .fill(.tint)
                .frame(width: 2, height: layout.height - TimelineLayout.rulerHeight)
                .offset(x: layout.x(preview.time) - 1, y: TimelineLayout.rulerHeight)
        }
    }

    /// The row a clip will be drawn in: its track's, or the empty lane of its
    /// kind in a project with no tracks yet.
    private func row(for placement: ClipPlacement) -> Int? {
        if !placement.isNewTrack { return layout.rowIndex(of: placement.trackID) }
        return layout.rows.firstIndex { $0.track == nil && $0.kind == placement.kind }
    }

    private func rect(for placement: ClipPlacement) -> CGRect {
        let x = layout.x(placement.range.start)
        let width = layout.x(placement.range.end) - x
        if let row = row(for: placement) {
            let top = layout.rowTop(row) + TimelineLayout.laneInset
            return CGRect(x: x, y: top, width: width, height: TimelineLayout.trackHeight - 2 * TimelineLayout.laneInset)
        }
        // A new video track goes above the others, and a new audio track
        // below.
        let barHeight = 4.0
        let y = placement.kind == .video ? TimelineLayout.rulerHeight : layout.height - barHeight
        return CGRect(x: x, y: y, width: width, height: barHeight)
    }
}
