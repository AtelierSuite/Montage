import CoreMedia
import MontageEngine
import SwiftUI

/// A video clip as a layer of the picture: where it sits in the frame, how
/// big and how turned it is, how see-through, and how it mixes with the
/// layers under it. Each value is shown, and set, at the playhead, with a
/// diamond to keyframe it.
struct LayerControls: View {
    @Environment(ProjectEditor.self) private var editor
    let clip: Clip

    var body: some View {
        if editor.skipReason(for: clip.id) == .tooManyLayers {
            Section {
                Label("Inspector.Layer.TooManyLayers", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.callout)
            }
        }
        Section {
            let position = parameter(\.transform.position)
            ParameterSlider("Inspector.Layer.X", position, in: -0.5...1.5, format: ParameterFormat.percent,
                            component: { Double($0.x) }, setComponent: { $0.x = $1 })
            ParameterSlider("Inspector.Layer.Y", position, in: -0.5...1.5, format: ParameterFormat.percent,
                            component: { Double($0.y) }, setComponent: { $0.y = $1 })
            ParameterSlider("Inspector.Layer.Scale", parameter(\.transform.scale), in: ClipTransform.scaleRange.lowerBound...4,
                            format: ParameterFormat.percent)
            ParameterSlider("Inspector.Layer.Rotation", parameter(\.transform.rotation), in: -180...180,
                            format: ParameterFormat.degrees)
            ParameterSlider("Inspector.Layer.Opacity", parameter(\.opacity), in: 0...1, format: ParameterFormat.percent)
            Picker("Inspector.Layer.BlendMode", selection: blendMode) {
                ForEach(MontageEngine.BlendMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Button("Inspector.Layer.Reset", systemImage: "arrow.counterclockwise") {
                editor.changeClip(clip.id, String(localized: "Inspector.Action.ResetTransform")) { $0.transform = ClipTransform() }
            }
            .disabled(clip.transform == ClipTransform())
        } header: {
            Text("Inspector.Layer")
        }
    }

    /// Edits one of the clip's parameters at the playhead.
    private func parameter<Value>(_ keyPath: WritableKeyPath<Clip, MontageEngine.Animatable<Value>>) -> ParameterEditing<Value> {
        let editor = editor
        let clipID = clip.id
        return ParameterEditing(
            parameter: clip[keyPath: keyPath], time: editor.clipTime(in: clip), canKeyframe: editor.isPlayheadOn(clip),
            change: { parameter, continuously in
                editor.changeClip(clipID, String(localized: "Inspector.Action.ChangeLayer"), continuously: continuously) {
                    $0[keyPath: keyPath] = parameter
                }
            },
            endChange: { editor.endGesture() }
        )
    }

    private var blendMode: Binding<MontageEngine.BlendMode> {
        let editor = editor
        let clipID = clip.id
        return Binding {
            clip.blendMode
        } set: { mode in
            editor.changeClip(clipID, String(localized: "Inspector.Action.ChangeLayer")) { $0.blendMode = mode }
        }
    }
}

extension MontageEngine.BlendMode {
    /// The mode's name, as the inspector lists it.
    var title: LocalizedStringKey {
        switch self {
        case .normal: "BlendMode.Normal"
        case .multiply: "BlendMode.Multiply"
        case .screen: "BlendMode.Screen"
        case .overlay: "BlendMode.Overlay"
        case .softLight: "BlendMode.SoftLight"
        case .hardLight: "BlendMode.HardLight"
        case .darken: "BlendMode.Darken"
        case .lighten: "BlendMode.Lighten"
        case .colorDodge: "BlendMode.ColorDodge"
        case .colorBurn: "BlendMode.ColorBurn"
        case .difference: "BlendMode.Difference"
        case .exclusion: "BlendMode.Exclusion"
        case .add: "BlendMode.Add"
        case .hue: "BlendMode.Hue"
        case .saturation: "BlendMode.Saturation"
        case .color: "BlendMode.Color"
        case .luminosity: "BlendMode.Luminosity"
        }
    }
}
