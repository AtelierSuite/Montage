import SwiftUI

/// The Liquid Glass bar that floats over the bottom of the editor on iOS,
/// keeping playback and editing within thumb reach. The Mac has these in a
/// bar between its preview and timeline instead.
struct EditorActionBar: View {
    /// Opens the library; nil where it's already beside the editor.
    var showLibrary: (() -> Void)?
    @Binding var isShowingInspector: Bool

    /// How wide the bar's room is, so the groups stay centred while they fit.
    @State private var width = 0.0

    var body: some View {
        // The full set of groups can be wider than a small iPhone, so the bar
        // scrolls sideways rather than clipping its end groups.
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    if let showLibrary {
                        group {
                            action("photo.on.rectangle.angled", label: "Toolbar.Library", perform: showLibrary)
                        }
                    }
                    // Nothing to play or edit until there's a timeline.
                    group {
                        action("backward.end.fill", label: "Transport.GoToStart", isEnabled: false) {}
                        action("play.fill", label: "Transport.Play", isEnabled: false) {}
                        action("forward.end.fill", label: "Transport.GoToEnd", isEnabled: false) {}
                    }
                    group {
                        action("scissors", label: "Edit.Split", isEnabled: false) {}
                        action("waveform", label: "Edit.DetachAudio", isEnabled: false) {}
                        action("trash", label: "Edit.Delete", isEnabled: false) {}
                    }
                    group {
                        action("slider.horizontal.3", isOn: isShowingInspector, label: "Toolbar.Inspector") {
                            isShowingInspector.toggle()
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(minWidth: width)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: Double.self) { $0.size.width } action: { width = $0 }
        .frame(height: 60)
    }

    private func group<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        // Packed tight, so all four groups fit across an iPhone.
        HStack(spacing: 0) {
            content()
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func action(
        _ symbol: String, isOn: Bool = false, label: LocalizedStringKey, isEnabled: Bool = true,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 42, height: 44)
                .contentShape(.circle)
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                // A round highlight, so an active control reads as a lit key.
                .background(isOn ? Color.accentColor.opacity(0.2) : .clear, in: .circle)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
