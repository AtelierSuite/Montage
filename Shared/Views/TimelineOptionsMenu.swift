import MontageEngine
import SwiftUI

/// How the timeline edits, in a menu beside the edit tools: snapping, how
/// trimming treats the clips after, selecting several clips by tapping,
/// whether preview plays proxies, and zoom, with the edits that have no
/// button of their own.
struct TimelineOptionsMenu<Label: View>: View {
    @Environment(ProjectEditor.self) private var editor
    @ViewBuilder let label: Label

    var body: some View {
        @Bindable var editor = editor
        @Bindable var timeline = editor.timeline
        Menu {
            Section {
                Toggle("Timeline.Snapping", systemImage: "arrow.right.and.line.vertical.and.arrow.left", isOn: $timeline.isSnapping)
                Toggle("Timeline.SelectMultiple", systemImage: "checkmark.circle", isOn: $timeline.selectsMultiple)
            }
            Picker("Timeline.TrimStyle", selection: $timeline.trimStyle) {
                Text("Timeline.TrimStyle.Trim").tag(TrimStyle.trim)
                Text("Timeline.TrimStyle.Ripple").tag(TrimStyle.ripple)
                Text("Timeline.TrimStyle.Roll").tag(TrimStyle.roll)
            }
            .pickerStyle(.menu)
            Section {
                Button("Edit.RippleDelete", systemImage: "delete.backward") { editor.deleteSelection(ripple: true) }
                    .disabled(!editor.canDelete)
                Button("Edit.AddMarker", systemImage: "bookmark") { editor.addMarkerAtPlayhead() }
                    .disabled(!editor.playback.hasContent)
                Button("Edit.AddCrossDissolve", systemImage: "square.split.diagonal") { editor.addCrossDissolve() }
                    .disabled(!editor.canAddTransition)
                Button("Edit.SelectAll", systemImage: "checklist") { editor.selectAllClips() }
            }
            Section {
                Button("Inspector.Keyframes.Previous", systemImage: "chevron.left.2") { editor.goToPreviousKeyframe() }
                    .disabled(editor.previousKeyframeTime == nil)
                Button("Inspector.Keyframes.Next", systemImage: "chevron.right.2") { editor.goToNextKeyframe() }
                    .disabled(editor.nextKeyframeTime == nil)
            }
            Section {
                Toggle("Preview.UseProxies", systemImage: "rectangle.compress.vertical", isOn: $editor.usesProxies)
            }
            Section {
                Button("Timeline.ZoomIn", systemImage: "plus.magnifyingglass") { timeline.zoom(by: 1.5) }
                Button("Timeline.ZoomOut", systemImage: "minus.magnifyingglass") { timeline.zoom(by: 1 / 1.5) }
            }
        } label: {
            label
        }
    }
}
