import MontageEngine
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
    @Environment(\.previewFrameReporter) private var previewFrameReporter
    @Environment(\.hidesPreviewPicture) private var hidesPreviewPicture
    @State private var showsControls = true
    /// The size the picture's laid out at, for taps on it to find the
    /// layer under them.
    @State private var pictureSize = CGSize.zero

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
                .opacity(hidesPreviewPicture ? 0 : 1)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                    previewFrameReporter?(frame)
                    pictureSize = frame.size
                }
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
                .overlay { ScreenshotStill(playback: editor.playback) }
                .overlay {
                    if !showsPlaybackOverlay && !hidesPreviewPicture {
                        PreviewCanvas()
                    }
                }
                .overlay {
                    if showsPlaybackOverlay && !hidesPreviewPicture {
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
                        .canvas(onTapPicture: tapPicture(at:)) { tap in
                            PreviewCanvas(catchesTaps: false, onTapPicture: tap)
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

    /// A tap on the picture under the playback controls: picks the layer
    /// under it, and says so, unless it's picked already, when the tap shows
    /// or hides the controls as ever. Away from every layer, it lets go of
    /// the selection.
    private func tapPicture(at location: CGPoint) -> Bool {
        guard !editor.playback.isPlaying else { return false }
        let mapping = PreviewMapping(renderSize: editor.project.settings.renderSize, viewSize: pictureSize)
        let point = mapping.renderPoint(fromView: location)
        let layer = editor.project.layer(at: point, time: editor.playback.currentTime, excluding: editor.clipsLeftOutOfPicture)
        guard layer?.clipID != editor.selectedClip?.id || layer == nil else { return false }
        if layer == nil && editor.selectedClipIDs.isEmpty { return false }
        editor.selectLayer(at: point)
        return layer != nil
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
    /// Hears where the preview's picture is on screen, for something to move
    /// into or out of it.
    @Entry var previewFrameReporter: PreviewFrameReporter?
    /// Leaves the preview's picture out, keeping its frame, while something
    /// else showing the picture moves into it.
    @Entry var hidesPreviewPicture = false
}

/// Hears where the preview's picture is on screen.
struct PreviewFrameReporter {
    let report: @MainActor (CGRect) -> Void

    @MainActor
    func callAsFunction(_ frame: CGRect) {
        report(frame)
    }
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
