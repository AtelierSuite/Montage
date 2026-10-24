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
    @Environment(\.expandPreview) private var expandPreview
    @Environment(\.floatPreview) private var floatPreview

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
                .contentShape(.rect)
                .onTapGesture { expandPreview?() }
                .accessibilityElement()
                .accessibilityLabel(Text("Preview.Title"))
                .accessibilityAddTraits(expandPreview == nil ? [] : .isButton)
                .accessibilityHint(expandPreview == nil ? Text(verbatim: "") : Text("Preview.Expand.Hint"))
                .overlay {
                    if let error = editor.playback.playbackError {
                        message(
                            systemImage: "exclamationmark.triangle", title: "Preview.Error.Title",
                            detail: Text(verbatim: error.localizedDescription)
                        )
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if let floatPreview {
                        Button("Preview.Float", systemImage: "pip.enter") { floatPreview() }
                            .labelStyle(.iconOnly)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .glassEffect(.regular.interactive(), in: .circle)
                            // A thumb's worth of room to hit, more than it shows.
                            .padding(7)
                            .contentShape(.rect)
                            .buttonStyle(.plain)
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

extension EnvironmentValues {
    /// Shows the preview full screen, where the platform can: tapping the
    /// preview calls it.
    @Entry var expandPreview: PreviewAction?
    /// Takes the preview out of the editor's layout into a window floating
    /// over it, where the platform can: a button on the preview calls it.
    @Entry var floatPreview: PreviewAction?
}

/// Something to do with the preview, given to it by whatever's around it.
struct PreviewAction {
    let perform: @MainActor () -> Void

    @MainActor
    func callAsFunction() {
        perform()
    }
}
