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
                control("Edit.Split", systemImage: "scissors") {}
                control("Edit.DetachAudio", systemImage: "waveform") {}
                control("Edit.Delete", systemImage: "trash") {}
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            // Nothing to act on until clips can be selected.
            .disabled(true)
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
