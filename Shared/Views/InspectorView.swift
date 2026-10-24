import SwiftUI

/// Settings for whatever is selected: a clip's effects, keyframes and audio.
struct InspectorView: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        if let (track, clip) = editor.inspectedClip {
            ClipInspector(track: track, clip: clip)
        } else {
            empty
        }
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("Inspector.Empty.Title", systemImage: "slider.horizontal.3")
        } description: {
            Text("Inspector.Empty.Message")
        }
    }
}
