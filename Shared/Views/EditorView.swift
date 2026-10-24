import SwiftUI

/// The editor's working area: the preview above, the transport and editing
/// controls between, and the timeline below. The library and inspector sit
/// around it, wherever each platform puts them.
///
/// Views can sit either side of the preview, such as controls on an iPhone
/// held sideways, where the preview is short and wide and the room beside it
/// would otherwise be empty. The preview then keeps to its own frame rather
/// than spreading its black across the width.
struct EditorView<Leading: View, Trailing: View>: View {
    /// Whether the transport and editing tools sit between the preview and
    /// the timeline. iOS keeps them in a bar floating over the bottom instead.
    var showsControlBar = true
    @ViewBuilder var previewLeading: Leading
    @ViewBuilder var previewTrailing: Trailing

    /// The most of the height the preview takes, however wide the editor is:
    /// a little more with views beside it, which need the height for theirs.
    private var maximumPreviewShare: Double { hasSideViews ? 0.66 : 0.6 }

    private var hasSideViews: Bool {
        Leading.self != EmptyView.self || Trailing.self != EmptyView.self
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // As tall as a 16:9 frame across the full width needs, so a
                // phone held upright gives the rest to the timeline.
                preview
                    .frame(height: min(geometry.size.width * 9 / 16 + 24, geometry.size.height * maximumPreviewShare))
                Divider()
                if showsControlBar {
                    EditorControlBar()
                    Divider()
                }
                TimelineView()
            }
        }
        .background { TransportShortcuts() }
    }

    @ViewBuilder
    private var preview: some View {
        if !hasSideViews {
            PreviewArea()
        } else {
            HStack(spacing: 0) {
                previewLeading
                PreviewArea(fillsWidth: false)
                previewTrailing
            }
            .padding(.horizontal, 8)
        }
    }
}

extension EditorView where Leading == EmptyView, Trailing == EmptyView {
    init(showsControlBar: Bool = true) {
        self.init(showsControlBar: showsControlBar, previewLeading: { EmptyView() }, previewTrailing: { EmptyView() })
    }
}
