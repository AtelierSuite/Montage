import SwiftUI

/// The editor's working area: the preview above, the transport and editing
/// controls between, and the timeline below. The library and inspector sit
/// around it, wherever each platform puts them.
struct EditorView: View {
    var body: some View {
        VStack(spacing: 0) {
            PreviewArea()
                .layoutPriority(1)
            Divider()
            EditorControlBar()
            Divider()
            TimelineView()
                .frame(minHeight: 160, idealHeight: 240)
        }
    }
}
