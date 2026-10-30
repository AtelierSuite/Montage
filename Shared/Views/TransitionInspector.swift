import CoreMedia
import MontageEngine
import SwiftUI

/// The inspector for a transition: what it is, how long it plays, and a
/// button to take it off.
struct TransitionInspector: View {
    @Environment(ProjectEditor.self) private var editor
    let transition: PlacedTransition

    var body: some View {
        let frames = editor.playback.frames
        let seconds = transition.timelineRange.duration.seconds
        // As long as both clips together, up to ten seconds.
        let longest = max(seconds, min(10, (transition.outgoing.duration + transition.incoming.duration).seconds))
        let frame = frames.frameDuration.seconds
        Form {
            Section {
                Text(transition.kind.title)
                    .font(.headline)
            }
            Section {
                LabeledContent("Inspector.Transition.Duration") {
                    Text(Duration.seconds(seconds), format: .units(allowed: [.seconds], fractionalPart: .show(length: 2)))
                        .monospacedDigit()
                }
                Slider(value: Binding { seconds } set: { editor.setSelectedTransitionDuration(seconds: $0) },
                       in: frame...max(longest, frame * 2))
                    .accessibilityLabel(Text("Inspector.Transition.Duration"))
                Stepper("Inspector.Transition.OneFrame") {
                    editor.setSelectedTransitionDuration(seconds: seconds + frame)
                } onDecrement: {
                    editor.setSelectedTransitionDuration(seconds: seconds - frame)
                }
            }
            Section {
                Button("Inspector.Transition.Remove", systemImage: "trash", role: .destructive) {
                    editor.removeSelectedTransition()
                }
            }
        }
        .formStyle(.grouped)
    }
}

extension ClipTransition.Kind {
    /// The transition's name, as the timeline and inspector show it.
    var title: String {
        switch self {
        case .crossDissolve: String(localized: "Transition.CrossDissolve")
        }
    }
}
