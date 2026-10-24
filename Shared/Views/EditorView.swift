import SwiftUI

/// The editor's working area: the preview above, the transport and editing
/// controls between, and the timeline below. The library and inspector sit
/// around it, wherever each platform puts them.
struct EditorView: View {
    /// Whether the transport and editing tools sit between the preview and
    /// the timeline. iOS keeps them in a bar floating over the bottom instead.
    var showsControlBar = true

    /// The most of the height the preview takes, however wide the editor is.
    private let maximumPreviewShare = 0.6

    var body: some View {
        GeometryReader { geometry in
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
        .background { TransportShortcuts() }
    }
}
