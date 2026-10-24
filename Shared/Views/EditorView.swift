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
struct EditorView<Controls: View>: View {
    /// Whether the transport and editing tools sit between the preview and
    /// the timeline. iOS keeps them in a bar floating over the bottom instead.
    var showsControlBar = true
    /// The controls under the preview, laying the editor out in columns.
    private var columnControls: Controls?

    /// The most of the height the preview takes, however wide the editor is.
    private let maximumPreviewShare = 0.6
    /// How much of the width the preview's column takes in columns, and the
    /// least it's made, for its controls to fit across.
    private let previewColumnShare = 0.25
    private let minimumPreviewColumnWidth = 190.0

    init(columnControls: () -> Controls) {
        showsControlBar = false
        self.columnControls = columnControls()
    }

    var body: some View {
        GeometryReader { geometry in
            if let columnControls {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        PreviewArea(fillsWidth: false)
                            .fixedSize(horizontal: false, vertical: true)
                        columnControls
                    }
                    .frame(width: max(minimumPreviewColumnWidth, geometry.size.width * previewColumnShare))
                    Divider()
                    TimelineView()
                }
            } else {
                VStack(spacing: 0) {
                    // As tall as a 16:9 frame across the full width needs, so a
                    // phone held upright gives the rest to the timeline.
                    PreviewArea()
                        .frame(height: min(geometry.size.width * 9 / 16 + 24, geometry.size.height * maximumPreviewShare))
                    Divider()
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
}

extension EditorView where Controls == EmptyView {
    init(showsControlBar: Bool = true) {
        self.showsControlBar = showsControlBar
        columnControls = nil
    }
}
