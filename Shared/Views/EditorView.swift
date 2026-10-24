import SwiftUI

/// The editor's working area: the preview above, the transport and editing
/// controls between, and the timeline below. The library and inspector sit
/// around it, wherever each platform puts them.
///
/// Given controls of its own, the editor lays out in two columns instead,
/// for an iPhone held sideways: the preview with the controls under it in a
/// narrow column, and the timeline taking the rest of the width and the
/// whole height, rather than a short, stretched preview over a short
/// timeline.
///
/// Either way, the divider between the preview and the timeline can be
/// dragged, and where it's left is kept for next time.
struct EditorView<Controls: View>: View {
    /// Whether the transport and editing tools sit between the preview and
    /// the timeline. iOS keeps them in a bar floating over the bottom instead.
    var showsControlBar = true
    /// The controls under the preview, laying the editor out in columns.
    private var columnControls: Controls?

    /// The share of the height the preview was last dragged to, stacked; nil
    /// until it's dragged, sizing the preview to fit the width instead.
    @AppStorage("Editor.PreviewHeightShare") private var previewHeightShare: Double?
    /// The share of the width the preview's column takes, in columns.
    @AppStorage("Editor.PreviewColumnShare") private var previewColumnShare = 0.25
    /// The preview's size along the drag when the divider's drag began.
    @State private var dragStartLength: Double?

    /// The most of the height the preview takes unless dragged further.
    private let defaultPreviewShare = 0.6
    /// The least the preview and the timeline are left with by a drag.
    private let minimumPreviewHeight = 100.0
    private let minimumTimelineHeight = 120.0
    /// The least the preview's column is made, for its controls to fit
    /// across, and the most of the width it can take.
    private let minimumPreviewColumnWidth = 190.0
    private let maximumPreviewColumnShare = 0.5

    init(columnControls: () -> Controls) {
        showsControlBar = false
        self.columnControls = columnControls()
    }

    var body: some View {
        GeometryReader { geometry in
            if let columnControls {
                let width = columnWidth(in: geometry.size.width)
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        PreviewArea(fillsWidth: false)
                            .fixedSize(horizontal: false, vertical: true)
                        columnControls
                    }
                    // A gutter along the divider for its grip, clear of the
                    // preview's frame.
                    .padding(.trailing, 8)
                    .frame(width: width)
                    ResizeHandle(axis: .horizontal) { distance in
                        let start = dragStartLength ?? width
                        dragStartLength = start
                        setColumnWidth(start + distance, in: geometry.size.width)
                    } onEnd: {
                        dragStartLength = nil
                    } onStep: { step in
                        setColumnWidth(width + step, in: geometry.size.width)
                    }
                    // Over the margin beside the controls, and the track
                    // headers, which only scroll.
                    .overhang(before: 24, after: 19)
                    TimelineView()
                }
            } else {
                let height = previewHeight(in: geometry.size)
                VStack(spacing: 0) {
                    PreviewArea()
                        .frame(height: height)
                    ResizeHandle(axis: .vertical) { distance in
                        let start = dragStartLength ?? height
                        dragStartLength = start
                        setPreviewHeight(start + distance, in: geometry.size.height)
                    } onEnd: {
                        dragStartLength = nil
                    } onStep: { step in
                        setPreviewHeight(height + step, in: geometry.size.height)
                    }
                    // Mostly over the black around the preview's frame, and
                    // hardly over the ruler, which is dragged along to scrub.
                    .overhang(before: 38, after: 5)
                    .gripOverDark()
                    if showsControlBar {
                        EditorControlBar()
                        Divider()
                    }
                    TimelineView()
                }
            }
        }
        .background { TransportShortcuts() }
    }

    // MARK: - Sizes

    /// Stacked, the preview is as tall as it was dragged to, or else as tall
    /// as a 16:9 frame across the full width needs, so a phone held upright
    /// gives the rest to the timeline.
    private func previewHeight(in size: CGSize) -> Double {
        let height = previewHeightShare.map { $0 * size.height }
            ?? min(size.width * 9 / 16 + 24, size.height * defaultPreviewShare)
        return clampedPreviewHeight(height, in: size.height)
    }

    private func setPreviewHeight(_ height: Double, in totalHeight: Double) {
        guard totalHeight > 0 else { return }
        previewHeightShare = clampedPreviewHeight(height, in: totalHeight) / totalHeight
    }

    private func clampedPreviewHeight(_ height: Double, in totalHeight: Double) -> Double {
        let maximum = max(minimumPreviewHeight, totalHeight - minimumTimelineHeight)
        return min(max(height, minimumPreviewHeight), maximum)
    }

    private func columnWidth(in totalWidth: Double) -> Double {
        clampedColumnWidth(previewColumnShare * totalWidth, in: totalWidth)
    }

    private func setColumnWidth(_ width: Double, in totalWidth: Double) {
        guard totalWidth > 0 else { return }
        previewColumnShare = clampedColumnWidth(width, in: totalWidth) / totalWidth
    }

    private func clampedColumnWidth(_ width: Double, in totalWidth: Double) -> Double {
        let maximum = max(minimumPreviewColumnWidth, totalWidth * maximumPreviewColumnShare)
        return min(max(width, minimumPreviewColumnWidth), maximum)
    }
}

extension EditorView where Controls == EmptyView {
    init(showsControlBar: Bool = true) {
        self.showsControlBar = showsControlBar
        columnControls = nil
    }
}
