import CoreGraphics
import MontageEngine
import SwiftUI

/// How text or a shape is filled: not at all, with a colour, or with a
/// gradient between two, each colour keyframeable.
struct FillControls: View {
    let editing: ClipEditing
    let fill: WritableKeyPath<Clip, LayerFill>
    /// Whether "none" is offered.
    var allowsNone = true

    var body: some View {
        let style = editing.clip[keyPath: fill].style
        Picker("Inspector.Fill", selection: editing.binding(fill.appending(path: \.style))) {
            ForEach(LayerFill.Style.allCases.filter { allowsNone || $0 != .none }, id: \.self) { style in
                Text(verbatim: style.title).tag(style)
            }
        }
        if style != .none {
            ColorParameterPicker(style == .solid ? "Inspector.Fill.Color" : "Inspector.Fill.StartColor",
                                 editing.parameter(fill.appending(path: \.color)))
        }
        if style == .linearGradient || style == .radialGradient {
            ColorParameterPicker("Inspector.Fill.EndColor", editing.parameter(fill.appending(path: \.endColor)))
        }
        if style == .linearGradient {
            ParameterSlider("Inspector.Fill.Angle", editing.parameter(fill.appending(path: \.angle)), in: 0...360,
                            format: ParameterFormat.degrees)
        }
    }
}

/// A shape's stroke or text's outline: on or off, its colour and width, and
/// for shapes, its dashes and how its ends and corners are drawn.
struct StrokeControls: View {
    let editing: ClipEditing
    let stroke: WritableKeyPath<Clip, LayerStroke>
    let title: LocalizedStringKey
    var showsLineStyle = true

    var body: some View {
        Toggle(title, isOn: editing.binding(stroke.appending(path: \.isEnabled)))
        if editing.clip[keyPath: stroke].isEnabled {
            ColorParameterPicker("Inspector.Stroke.Color", editing.parameter(stroke.appending(path: \.color)))
            ParameterSlider("Inspector.Stroke.Width", editing.parameter(stroke.appending(path: \.width)), in: 0...60,
                            format: ParameterFormat.whole)
            if showsLineStyle {
                Picker("Inspector.Stroke.Dash", selection: editing.binding(stroke.appending(path: \.dash))) {
                    ForEach(LayerStroke.Dash.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                Picker("Inspector.Stroke.Cap", selection: editing.binding(stroke.appending(path: \.cap))) {
                    ForEach(LayerStroke.Cap.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
                Picker("Inspector.Stroke.Join", selection: editing.binding(stroke.appending(path: \.join))) {
                    ForEach(LayerStroke.Join.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
                }
            }
        }
    }
}

/// A shadow: on or off, its colour, how soft it is and where it falls.
struct ShadowControls: View {
    let editing: ClipEditing
    let shadow: WritableKeyPath<Clip, LayerShadow>

    var body: some View {
        Toggle("Inspector.Shadow", isOn: editing.binding(shadow.appending(path: \.isEnabled)))
        if editing.clip[keyPath: shadow].isEnabled {
            let offset = editing.parameter(shadow.appending(path: \.offset))
            ColorParameterPicker("Inspector.Shadow.Color", editing.parameter(shadow.appending(path: \.color)))
            ParameterSlider("Inspector.Shadow.Blur", editing.parameter(shadow.appending(path: \.blur)), in: 0...100,
                            format: ParameterFormat.whole)
            ParameterSlider("Inspector.Shadow.OffsetX", offset, in: -100...100, format: ParameterFormat.whole,
                            component: { Double($0.width) }, setComponent: { $0.width = $1 })
            ParameterSlider("Inspector.Shadow.OffsetY", offset, in: -100...100, format: ParameterFormat.whole,
                            component: { Double($0.height) }, setComponent: { $0.height = $1 })
        }
    }
}
