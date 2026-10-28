import SwiftUI

/// Settings for whatever is selected: a clip's effects, keyframes and
/// audio, or a transition's length.
struct InspectorView: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        if let (track, clip) = editor.inspectedClip {
            ClipInspector(track: track, clip: clip)
        } else if let transition = editor.selectedTransition {
            TransitionInspector(transition: transition)
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
