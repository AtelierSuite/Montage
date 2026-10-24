import CoreGraphics
import MontageEngine
import SwiftUI

/// A shape clip's shape and how it's painted: its kind and size, its
/// corners, sides or points, then its fill, stroke and shadow, each value
/// keyframeable at the playhead.
struct ShapeInspector: View {
    let editing: ClipEditing

    var body: some View {
        let shape = editing.clip.shapeContent
        let size = editing.parameter(\.shapeContent.size)
        // Up to twice the frame, so a shape can overflow it.
        let frame = editing.editor.project.settings.renderSize
        let maximum = max(frame.width, frame.height) * 2
        Section("Inspector.Shape") {
            Picker("Inspector.Shape.Kind", selection: Binding {
                shape.kind
            } set: { kind in
                editing.change { $0.shapeContent.changeKind(to: kind) }
            }) {
                ForEach(ShapeContent.Kind.allCases, id: \.self) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            ParameterSlider("Inspector.Shape.Width", size, in: 0...max(1, frame.width * 2), format: ParameterFormat.whole,
                            component: { Double($0.width) }, setComponent: { $0.width = $1 })
            if shape.kind != .line {
                ParameterSlider("Inspector.Shape.Height", size, in: 0...max(1, frame.height * 2), format: ParameterFormat.whole,
                                component: { Double($0.height) }, setComponent: { $0.height = $1 })
            }
            if shape.kind == .roundedRectangle {
                ParameterSlider("Inspector.Shape.CornerRadius", editing.parameter(\.shapeContent.cornerRadius), in: 0...max(1, maximum / 4),
                                format: ParameterFormat.whole)
            }
            if shape.kind == .polygon || shape.kind == .star {
                Stepper(value: editing.binding(\.shapeContent.sides), in: 3...24) {
                    LabeledContent(shape.kind == .star ? "Inspector.Shape.Points" : "Inspector.Shape.Sides") {
                        Text(verbatim: shape.sides.formatted())
                    }
                }
            }
            if shape.kind == .star {
                ParameterSlider("Inspector.Shape.InnerRadius", editing.parameter(\.shapeContent.innerRadius), in: 0.05...1,
                                format: ParameterFormat.percent)
            }
        }
        if shape.kind != .line {
            Section("Inspector.Fill") {
                FillControls(editing: editing, fill: \.shapeContent.fill)
            }
        }
        Section {
            StrokeControls(editing: editing, stroke: \.shapeContent.stroke, title: "Inspector.Stroke")
        }
        Section {
            ShadowControls(editing: editing, shadow: \.shapeContent.shadow)
        }
    }
}
