import SwiftUI

/// Playback from the keyboard: Space plays and pauses, and the left and right
/// arrows step back and forward a frame. Buttons nobody sees, so the keys
/// work wherever in the editor the focus is.
struct TransportShortcuts: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        let playback = editor.playback
        ZStack {
            Button("Transport.Play") { playback.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
            Button("Transport.StepBackward") { playback.step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Transport.StepForward") { playback.step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
        .disabled(!playback.hasContent)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
