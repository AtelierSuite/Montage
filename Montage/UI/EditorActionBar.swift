import SwiftUI

/// The Liquid Glass bar that floats over the bottom of the editor on iOS,
/// keeping editing within thumb reach; playback is over the preview. The
/// Mac has these in a bar between its preview and timeline instead.
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
                    AddActions(axis: .horizontal)
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
/// timeline: the editing tools, then the library and the inspector.
/// Playback is over the preview. The groups fill each row as far as the column's width
/// allows, so a wider column takes fewer rows, leaving room for its taller
/// preview.
struct EditorActionPanel: View {
    /// Opens the library; nil where it's already beside the editor.
    var showLibrary: (() -> Void)?
    @Binding var isShowingInspector: Bool

    var body: some View {
        // Scrolls if a short screen can't fit the whole panel.
        ScrollView(.vertical) {
            GlassEffectContainer(spacing: 10) {
                RowsLayout(spacing: 10) {
                    HStack(spacing: 10) {
                        AddActions(axis: .horizontal)
                        EditActions(axis: .horizontal)
                    }
                    // Kept together, so they don't split across rows.
                    HStack(spacing: 10) {
                        if let showLibrary {
                            LibraryActions(axis: .horizontal, showLibrary: showLibrary)
                        }
                        InspectorActions(axis: .horizontal, isShowingInspector: $isShowingInspector)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// Lays views out in rows, as many to a row as fit across, each row
/// centred, like words in a centred paragraph.
private struct RowsLayout: Layout {
    var spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, across: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * Double(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(of: subviews, across: bounds.width) {
            var x = bounds.midX - row.width / 2
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width = 0.0
        var height = 0.0
    }

    /// Fills each row in turn until the next view wouldn't fit across.
    private func rows(of subviews: Subviews, across width: Double) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let widthWithView = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty && widthWithView > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
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

/// Adds text, a shape or an image at the playhead.
private struct AddActions: View {
    let axis: Axis

    var body: some View {
        ActionGroup(axis: axis) {
            AddLayerMenu {
                Image(systemName: "plus")
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
                    .foregroundStyle(.primary)
            }
            // Plain, so the menu doesn't tint its label like the other buttons.
            .menuStyle(.button)
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Add.Menu"))
        }
    }
}

/// The edits to the selected clips, or at the playhead, and how the
/// timeline edits. Split and Delete have their keys for a hardware keyboard.
private struct EditActions: View {
    let axis: Axis
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        ActionGroup(axis: axis) {
            ActionButton("scissors", label: "Edit.Split", isEnabled: editor.canSplit) { editor.splitAtPlayhead() }
                .keyboardShortcut("b", modifiers: .command)
            ActionButton("waveform", label: "Edit.DetachAudio", isEnabled: editor.canDetachAudio) { editor.detachAudio() }
            ActionButton("trash", label: "Edit.Delete", isEnabled: editor.canDelete) { editor.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: .command)
            TimelineOptionsMenu {
                Image(systemName: "slider.horizontal.below.rectangle")
                    .font(.system(size: 17))
                    .frame(width: 44, height: 44)
                    .contentShape(.circle)
                    .foregroundStyle(.primary)
            }
            .accessibilityLabel(Text("Timeline.Options"))
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
                .frame(width: 44, height: 44)
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
