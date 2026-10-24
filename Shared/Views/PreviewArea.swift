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
    @Environment(\.showsPlaybackOverlay) private var showsPlaybackOverlay
    @Environment(\.previewTransition) private var previewTransition
    @State private var showsControls = true

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
                .modifier(PreviewTransitionSource(transition: previewTransition))
                .accessibilityElement()
                .accessibilityLabel(Text("Preview.Title"))
                .overlay {
                    if let error = editor.playback.playbackError {
                        message(
                            systemImage: "exclamationmark.triangle", title: "Preview.Error.Title",
                            detail: Text(verbatim: error.localizedDescription)
                        )
                    }
                }
                .overlay {
                    if showsPlaybackOverlay {
                        PlaybackOverlay(playback: editor.playback, isShown: $showsControls) {
                            HStack {
                                if let expandPreview {
                                    PlaybackOverlayButton("Preview.Expand", systemImage: "arrow.up.left.and.arrow.down.right") {
                                        expandPreview()
                                    }
                                }
                                Spacer(minLength: 0)
                                if let floatPreview {
                                    PlaybackOverlayButton("Preview.Float", systemImage: "pip.enter") { floatPreview() }
                                }
                            }
                        }
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
    /// Shows the preview full screen, where the platform can: a button on the
    /// preview calls it.
    @Entry var expandPreview: PreviewAction?
    /// Takes the preview out of the editor's layout into a window floating
    /// over it, where the platform can: a button on the preview calls it.
    @Entry var floatPreview: PreviewAction?
    /// Whether the preview has its playback controls over the picture, as
    /// on iOS, rather than in a bar of their own.
    @Entry var showsPlaybackOverlay = false
    /// What a transition out of the preview, such as into full screen, grows
    /// from.
    @Entry var previewTransition: PreviewTransition?
}

/// Names the preview as the source of a transition.
struct PreviewTransition {
    let id: String
    let namespace: Namespace.ID
}

/// Marks the preview as where its transition grows from, where there is one.
private struct PreviewTransitionSource: ViewModifier {
    let transition: PreviewTransition?

    func body(content: Content) -> some View {
        #if os(iOS)
        if let transition {
            content.matchedTransitionSource(id: transition.id, in: transition.namespace)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// Something to do with the preview, given to it by whatever's around it.
struct PreviewAction {
    let perform: @MainActor () -> Void

    @MainActor
    func callAsFunction() {
        perform()
    }
}
