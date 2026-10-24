import SwiftUI

/// Settings for whatever is selected: a clip's effects, keyframes and audio.
struct InspectorView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Inspector.Empty.Title", systemImage: "slider.horizontal.3")
        } description: {
            Text("Inspector.Empty.Message")
        }
    }
}
