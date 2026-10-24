import CoreGraphics
import MontageEngine
import SwiftUI

/// The mask an effect is limited to: its shape, or none for the whole
/// picture, and where it sits, how big, how turned and how soft it is.
struct MaskControls: View {
    @Environment(ProjectEditor.self) private var editor
    let editing: EffectEditing

    var body: some View {
        let mask = editing.effect.mask
        Picker("Inspector.Mask", selection: shape) {
            Text("Inspector.Mask.None").tag(Mask.Shape?.none)
            Text("Inspector.Mask.Rectangle").tag(Mask.Shape?.some(.rectangle))
            Text("Inspector.Mask.Ellipse").tag(Mask.Shape?.some(.ellipse))
            Text("Inspector.Mask.Path").tag(Mask.Shape?.some(.path))
        }
        if mask != nil {
            Toggle("Inspector.Mask.EditInPreview", systemImage: "hand.point.up.left", isOn: editsInPreview)
            let center = editing.parameter(\.maskOrDefault.center)
            let size = editing.parameter(\.maskOrDefault.size)
            ParameterSlider("Inspector.Mask.X", center, in: 0...1, format: ParameterFormat.percent,
                            component: { Double($0.x) }, setComponent: { $0.x = $1 })
            ParameterSlider("Inspector.Mask.Y", center, in: 0...1, format: ParameterFormat.percent,
                            component: { Double($0.y) }, setComponent: { $0.y = $1 })
            ParameterSlider("Inspector.Mask.Width", size, in: 0...1.5, format: ParameterFormat.percent,
                            component: { Double($0.width) }, setComponent: { $0.width = $1 })
            ParameterSlider("Inspector.Mask.Height", size, in: 0...1.5, format: ParameterFormat.percent,
                            component: { Double($0.height) }, setComponent: { $0.height = $1 })
            ParameterSlider("Inspector.Mask.Rotation", editing.parameter(\.maskOrDefault.rotation), in: -180...180,
                            format: ParameterFormat.degrees)
            ParameterSlider("Inspector.Mask.Feather", editing.parameter(\.maskOrDefault.feather), in: 0...0.2,
                            format: ParameterFormat.percent)
            Toggle("Inspector.Mask.Invert", isOn: editing.binding(\.maskOrDefault.isInverted))
        }
    }

    /// Whether the preview has handles for this mask, in place of the
    /// clip's own.
    private var editsInPreview: Binding<Bool> {
        let timeline = editor.timeline
        let effectID = editing.effect.id
        return Binding {
            timeline.editedMaskEffectID == effectID
        } set: { isOn in
            timeline.editedMaskEffectID = isOn ? effectID : nil
        }
    }

    /// The mask's shape; choosing one for an effect without a mask gives it
    /// a new one, and choosing none takes it away.
    private var shape: Binding<Mask.Shape?> {
        Binding {
            editing.effect.mask?.shape
        } set: { shape in
            editing.change { effect in
                guard let shape else {
                    effect.mask = nil
                    return
                }
                if effect.mask == nil {
                    effect.mask = Mask(shape)
                    // A new mask is edited where it's seen.
                    editor.timeline.editedMaskEffectID = effect.id
                } else {
                    effect.mask?.shape = shape
                }
            }
        }
    }
}
