import CoreGraphics
import MontageEngine
import SwiftUI

/// A mosaic's style, how coarse and how strong it is, and the
/// checkerboard's colours.
struct MosaicControls: View {
    let editing: EffectEditing

    var body: some View {
        let style = editing.effect.mosaic.style
        Picker("Inspector.Mosaic.Style", selection: editing.binding(\.mosaic.style)) {
            Text("Inspector.Mosaic.Style.Pixelate").tag(Mosaic.Style.pixelate)
            Text("Inspector.Mosaic.Style.Blur").tag(Mosaic.Style.blur)
            Text("Inspector.Mosaic.Style.Checkerboard").tag(Mosaic.Style.checkerboard)
        }
        ParameterSlider(style == .blur ? "Inspector.Mosaic.Radius" : "Inspector.Mosaic.Size",
                        editing.parameter(\.mosaic.scale), in: 0.002...0.2, format: ParameterFormat.percent)
        ParameterSlider("Inspector.Mosaic.Strength", editing.parameter(\.mosaic.strength), in: 0...1,
                        format: ParameterFormat.percent)
        if style == .checkerboard {
            ColorParameterPicker("Inspector.Mosaic.FirstColor", editing.parameter(\.mosaic.firstColor))
            ColorParameterPicker("Inspector.Mosaic.SecondColor", editing.parameter(\.mosaic.secondColor))
        }
    }
}

/// A colour well for a colour parameter, set at the playhead, with a button
/// to keyframe it there. Dragging about in the colour panel is one undo
/// step.
struct ColorParameterPicker: View {
    @Environment(ProjectEditor.self) private var editor
    private let title: LocalizedStringKey
    private let editing: ParameterEditing<RGBAColor>
    /// Whose changes join one undo step: this well's.
    @State private var coalescingKey = UUID()

    init(_ title: LocalizedStringKey, _ editing: ParameterEditing<RGBAColor>) {
        self.title = title
        self.editing = editing
    }

    var body: some View {
        HStack {
            ColorPicker(title, selection: Binding {
                editing.value.cgColor
            } set: { color in
                guard let color = RGBAColor(color) else { return }
                editor.coalescingChanges(coalescingKey) { editing.set(color) }
            })
            KeyframeButton(editing: editing)
        }
    }
}

extension RGBAColor {
    /// The colour in sRGB, as the model keeps it.
    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])
            ?? CGColor(gray: 0, alpha: 1)
    }

    /// A colour from any colour space, in sRGB.
    init?(_ color: CGColor) {
        guard let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let components = srgb.components, components.count >= 4 else { return nil }
        self.init(red: components[0], green: components[1], blue: components[2], alpha: components[3])
    }
}
