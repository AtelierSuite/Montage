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
                        LibraryActions(axis: .horizontal, showLibrary: showLibrary)
                    }
                    TransportActions(axis: .horizontal)
                    EditActions(axis: .horizontal)
                    InspectorActions(axis: .horizontal, isShowingInspector: $isShowingInspector)
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
}

/// The editor's controls as a panel under the preview, for an iPhone held
/// sideways, where the preview and its controls share a column beside the
/// timeline: playback first, then the editing tools, then the library and
/// the inspector.
struct EditorActionPanel: View {
    /// Opens the library; nil where it's already beside the editor.
    var showLibrary: (() -> Void)?
    @Binding var isShowingInspector: Bool

    var body: some View {
        // Scrolls if a short screen can't fit the whole panel.
        ScrollView(.vertical) {
            GlassEffectContainer(spacing: 10) {
                VStack(spacing: 10) {
                    TransportActions(axis: .horizontal)
                    EditActions(axis: .horizontal)
                    HStack(spacing: 10) {
                        if let showLibrary {
                            LibraryActions(axis: .horizontal, showLibrary: showLibrary)
                        }
                        InspectorActions(axis: .horizontal, isShowingInspector: $isShowingInspector)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Groups

private struct LibraryActions: View {
    let axis: Axis
    let showLibrary: () -> Void

    var body: some View {
        ActionGroup(axis: axis) {
            ActionButton("photo.on.rectangle.angled", label: "Toolbar.Library", perform: showLibrary)
        }
    }
}

/// Nothing to play until there's something on the timeline.
private struct TransportActions: View {
    let axis: Axis

    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        let playback = editor.playback
        ActionGroup(axis: axis) {
            ActionButton("backward.end.fill", label: "Transport.GoToStart", isEnabled: playback.hasContent) {
                playback.goToStart()
            }
            ActionButton(
                playback.isPlaying ? "pause.fill" : "play.fill",
                label: playback.isPlaying ? "Transport.Pause" : "Transport.Play", isEnabled: playback.hasContent
            ) {
                playback.togglePlayPause()
            }
            ActionButton("forward.end.fill", label: "Transport.GoToEnd", isEnabled: playback.hasContent) {
                playback.goToEnd()
            }
        }
    }
}

/// Nothing to edit until clips can be selected.
private struct EditActions: View {
    let axis: Axis

    var body: some View {
        ActionGroup(axis: axis) {
            ActionButton("scissors", label: "Edit.Split", isEnabled: false) {}
            ActionButton("waveform", label: "Edit.DetachAudio", isEnabled: false) {}
            ActionButton("trash", label: "Edit.Delete", isEnabled: false) {}
        }
    }
}

private struct InspectorActions: View {
    let axis: Axis
    @Binding var isShowingInspector: Bool

    var body: some View {
        ActionGroup(axis: axis) {
            ActionButton("slider.horizontal.3", isOn: isShowingInspector, label: "Toolbar.Inspector") {
                isShowingInspector.toggle()
            }
        }
    }
}

// MARK: - Pieces

/// Buttons packed tight in one capsule of glass, so all four groups fit
/// across an iPhone.
private struct ActionGroup<Content: View>: View {
    let axis: Axis
    @ViewBuilder let content: Content

    var body: some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            content
        }
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

private struct ActionButton: View {
    let symbol: String
    var isOn = false
    let label: LocalizedStringKey
    var isEnabled = true
    let perform: () -> Void

    init(
        _ symbol: String, isOn: Bool = false, label: LocalizedStringKey, isEnabled: Bool = true,
        perform: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.isOn = isOn
        self.label = label
        self.isEnabled = isEnabled
        self.perform = perform
    }

    var body: some View {
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
