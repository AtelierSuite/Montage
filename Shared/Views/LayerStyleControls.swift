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

/// Where a clip's picture sits in the frame, how it's fitted, how see-through
/// it is and how it mixes with the layers under it, with a pan and zoom for
/// stills.
struct LayerControls: View {
    let editing: ClipEditing
    let isStill: Bool

    var body: some View {
        let clip = editing.clip
        let position = editing.parameter(\.transform.position)
        if !clip.content.isGenerated {
            Picker("Inspector.Fit", selection: editing.binding(\.fit)) {
                ForEach(FrameFit.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
            }
        }
        if isStill {
            Toggle("Inspector.KenBurns", isOn: Binding {
                clip.hasKenBurns
            } set: { isOn in
                editing.change { isOn ? $0.applyKenBurns() : $0.removeKenBurns() }
            })
        }
        ParameterSlider("Inspector.Layer.X", position, in: -0.5...1.5, format: ParameterFormat.percent,
                        component: { Double($0.x) }, setComponent: { $0.x = $1 })
        ParameterSlider("Inspector.Layer.Y", position, in: -0.5...1.5, format: ParameterFormat.percent,
                        component: { Double($0.y) }, setComponent: { $0.y = $1 })
        ParameterSlider("Inspector.Layer.Scale", editing.parameter(\.transform.scale), in: 0...4, format: ParameterFormat.percent)
        ParameterSlider("Inspector.Layer.Rotation", editing.parameter(\.transform.rotation), in: -180...180,
                        format: ParameterFormat.degrees)
        ParameterSlider("Inspector.Layer.Opacity", editing.parameter(\.opacity), in: 0...1, format: ParameterFormat.percent)
        Picker("Inspector.Layer.BlendMode", selection: editing.binding(\.blendMode)) {
            ForEach(MontageEngine.BlendMode.allCases, id: \.self) { Text(verbatim: $0.title).tag($0) }
        }
    }
}

extension MontageEngine.BlendMode {
    var title: String {
        switch self {
        case .normal: String(localized: "BlendMode.Normal")
        case .multiply: String(localized: "BlendMode.Multiply")
        case .screen: String(localized: "BlendMode.Screen")
        case .overlay: String(localized: "BlendMode.Overlay")
        case .softLight: String(localized: "BlendMode.SoftLight")
        case .hardLight: String(localized: "BlendMode.HardLight")
        case .darken: String(localized: "BlendMode.Darken")
        case .lighten: String(localized: "BlendMode.Lighten")
        case .colorDodge: String(localized: "BlendMode.ColorDodge")
        case .colorBurn: String(localized: "BlendMode.ColorBurn")
        case .difference: String(localized: "BlendMode.Difference")
        case .exclusion: String(localized: "BlendMode.Exclusion")
        case .add: String(localized: "BlendMode.Add")
        case .hue: String(localized: "BlendMode.Hue")
        case .saturation: String(localized: "BlendMode.Saturation")
        case .color: String(localized: "BlendMode.Color")
        case .luminosity: String(localized: "BlendMode.Luminosity")
        }
    }
}
