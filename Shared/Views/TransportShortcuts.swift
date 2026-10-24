import SwiftUI

/// Playback from the keyboard: Space plays and pauses, and the left and right
/// arrows step back and forward a frame. Buttons nobody sees, so the keys
/// work wherever in the editor the focus is. On iOS, Option-[ and Option-]
/// also go to the selected clip's previous and next keyframes, which the
/// Mac has in its Edit menu.
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
            #if os(iOS)
            Button("Inspector.Keyframes.Previous") { editor.goToPreviousKeyframe() }
                .keyboardShortcut("[", modifiers: .option)
            Button("Inspector.Keyframes.Next") { editor.goToNextKeyframe() }
                .keyboardShortcut("]", modifiers: .option)
            #endif
        }
        .disabled(!playback.hasContent)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
