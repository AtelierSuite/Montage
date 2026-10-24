import SwiftUI

/// Where the project plays back: a frame the shape of the project's video,
/// fitted into whatever room the editor leaves it, on black like a viewer.
/// Until there's something on the timeline, the frame says how to start.
struct PreviewArea: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        ZStack {
            Color.black
            frame
                .aspectRatio(aspectRatio, contentMode: .fit)
                .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var frame: some View {
        if editor.playback.hasContent {
            PlayerView(player: editor.playback.player)
        } else {
            Rectangle()
                .fill(Color(white: 0.08))
                .overlay {
                    VStack(spacing: 6) {
                        Image(systemName: "film")
                            .font(.largeTitle)
                        Text("Preview.Empty.Title")
                            .font(.headline)
                        Text("Preview.Empty.Message")
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding()
                }
        }
    }

    /// The project's frame shape, or 16:9 if its settings have none.
    private var aspectRatio: Double {
        let size = editor.project.settings.renderSize
        return size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9
    }
}
