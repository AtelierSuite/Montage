import SwiftUI

/// Where the project plays back: a frame the shape of the project's video,
/// fitted into whatever room the editor leaves it, on black like a viewer.
/// Until there's something on the timeline, the frame says how to start.
struct PreviewArea: View {
    /// Whether the black runs the full width of the room, like a viewer.
    /// Otherwise it keeps to the frame, for when the room is much wider than
    /// the frame and a band of black would only stretch it out.
    var fillsWidth = true

    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        if fillsWidth {
            ZStack {
                Color.black
                frame
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            frame
                .aspectRatio(aspectRatio, contentMode: .fit)
                .background(.black)
                .clipShape(.rect(cornerRadius: 10))
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var frame: some View {
        if editor.playback.hasContent {
            PlayerView(player: editor.playback.player)
                .overlay {
                    if let error = editor.playback.playbackError {
                        message(
                            systemImage: "exclamationmark.triangle", title: "Preview.Error.Title",
                            detail: Text(verbatim: error.localizedDescription)
                        )
                    }
                }
        } else {
            Rectangle()
                .fill(Color(white: 0.08))
                .overlay {
                    message(systemImage: "film", title: "Preview.Empty.Title", detail: Text("Preview.Empty.Message"))
                }
        }
    }

    private func message(systemImage: String, title: LocalizedStringKey, detail: Text) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.largeTitle)
            Text(title)
                .font(.headline)
            detail
                .font(.subheadline)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.6))
        .padding()
    }

    /// The project's frame shape, or 16:9 if its settings have none.
    private var aspectRatio: Double {
        let size = editor.project.settings.renderSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }
}
