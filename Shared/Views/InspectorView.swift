import SwiftUI

/// Settings for whatever is selected: a clip's effects, keyframes and audio.
struct InspectorView: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        if let clipID = editor.selectedClipID, editor.project.clip(id: clipID) != nil {
            Form {
                AudioEffectsSection(clipID: clipID)
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView {
                Label("Inspector.Empty.Title", systemImage: "slider.horizontal.3")
            } description: {
                Text("Inspector.Empty.Message")
            }
        }
    }
}
