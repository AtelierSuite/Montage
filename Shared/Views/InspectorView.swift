import SwiftUI

/// Settings for whatever is selected: a clip's effects, keyframes and audio.
struct InspectorView: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        // Sound is all there is to inspect so far: a clip without any shows
        // the empty state rather than an empty form.
        if let clipID = editor.selectedClipID, let (track, clip) = editor.project.clip(id: clipID),
           AudioEffectsSection.hasSound(clip, on: track, in: editor.project) {
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
