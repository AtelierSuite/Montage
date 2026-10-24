import SwiftUI

/// The bar between the preview and the timeline on the Mac: the transport,
/// and the tools that act on the selected clips.
struct EditorControlBar: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        let playback = editor.playback
        HStack {
            // Balances the tools on the trailing side, so the transport sits
            // in the middle.
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: 0)

            HStack(spacing: 20) {
                control("Transport.GoToStart", systemImage: "backward.end.fill") { playback.goToStart() }
                if playback.isPlaying {
                    control("Transport.Pause", systemImage: "pause.fill") { playback.pause() }
                        .font(.title2)
                } else {
                    control("Transport.Play", systemImage: "play.fill") { playback.play() }
                        .font(.title2)
                }
                control("Transport.GoToEnd", systemImage: "forward.end.fill") { playback.goToEnd() }
            }
            // Nothing to play until there's something on the timeline.
            .disabled(!playback.hasContent)

            HStack(spacing: 16) {
                control("Edit.Split", systemImage: "scissors") { editor.splitAtPlayhead() }
                    .disabled(!editor.canSplit)
                control("Edit.DetachAudio", systemImage: "waveform") { editor.detachAudio() }
                    .disabled(!editor.canDetachAudio)
                control("Edit.Delete", systemImage: "trash") { editor.deleteSelection() }
                    .disabled(!editor.canDelete)
                TimelineOptionsMenu {
                    Label("Timeline.Options", systemImage: "slider.horizontal.below.rectangle")
                        .labelStyle(.iconOnly)
                }
                .menuIndicator(.hidden)
                .fixedSize()
                .help(Text("Timeline.Options"))
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .buttonStyle(.borderless)
    }

    private func control(_ title: LocalizedStringKey, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .help(Text(title))
    }
}
