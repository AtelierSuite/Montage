import SwiftUI

/// The media imported into the project, ready to be added to the timeline.
struct LibraryView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Library.Empty.Title", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Library.Empty.Message")
        } actions: {
            Button("Library.Import") {
            }
            .disabled(true)
        }
    }
}
