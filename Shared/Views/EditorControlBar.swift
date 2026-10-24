import SwiftUI

/// The bar between the preview and the timeline: the playhead's timecode,
/// the transport, and the tools that act on the selected clips.
struct EditorControlBar: View {
    var body: some View {
        HStack {
            Text(verbatim: "00:00:00:00")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 20) {
                control("Transport.GoToStart", systemImage: "backward.end.fill")
                control("Transport.Play", systemImage: "play.fill")
                    .font(.title2)
                control("Transport.GoToEnd", systemImage: "forward.end.fill")
            }

            HStack(spacing: 16) {
                control("Edit.Split", systemImage: "scissors")
                control("Edit.DetachAudio", systemImage: "waveform")
                control("Edit.Delete", systemImage: "trash")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .buttonStyle(.borderless)
        // Nothing to act on until there's a timeline to play and edit.
        .disabled(true)
    }

    private func control(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Button {
        } label: {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
        .help(Text(title))
    }
}
