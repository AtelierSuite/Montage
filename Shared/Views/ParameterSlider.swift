import CoreMedia
import MontageEngine
import SwiftUI

/// How an inspector control changes one of an effect's parameters: at the
/// playhead, either at once or as a drag goes.
@MainActor
struct ParameterEditing<Value: Interpolatable> {
    /// The parameter as it is.
    var parameter: MontageEngine.Animatable<Value>
    /// The playhead's time in the clip, where values are shown and set.
    var time: CMTime
    /// Whether the playhead is on the clip, for keyframes to be set there.
    var canKeyframe: Bool
    /// Puts in a changed parameter; `continuously` while a drag goes on.
    var change: (_ parameter: MontageEngine.Animatable<Value>, _ continuously: Bool) -> Void
    /// Ends a drag, making its changes one undo step.
    var endChange: () -> Void

    var value: Value { parameter.value(at: time) }

    /// Sets the value at the playhead: throughout, or as a keyframe there
    /// once the parameter has keyframes.
    func set(_ value: Value, continuously: Bool = false) {
        var parameter = parameter
        parameter.set(value, at: time)
        change(parameter, continuously)
    }
}

/// A parameter's name and value over a slider, with a button to keyframe it
/// at the playhead. Shows one number of the parameter, such as one channel
/// of a colour's.
struct ParameterSlider<Value: Interpolatable>: View {
    private let title: LocalizedStringKey
    private let editing: ParameterEditing<Value>
    private let range: ClosedRange<Double>
    private let format: (Double) -> String
    private let component: (Value) -> Double
    private let setComponent: (inout Value, Double) -> Void

    /// Whether the slider's being dragged, so each move isn't an undo step.
    @State private var isDragging = false

    init(
        _ title: LocalizedStringKey, _ editing: ParameterEditing<Value>, in range: ClosedRange<Double>,
        format: @escaping (Double) -> String = ParameterFormat.decimal,
        component: @escaping (Value) -> Double, setComponent: @escaping (inout Value, Double) -> Void
    ) {
        self.title = title
        self.editing = editing
        self.range = range
        self.format = format
        self.component = component
        self.setComponent = setComponent
    }

    var body: some View {
        let value = component(editing.value)
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                KeyframeButton(editing: editing)
            }
            Slider(value: Binding {
                min(max(value, range.lowerBound), range.upperBound)
            } set: { newValue in
                var whole = editing.value
                setComponent(&whole, newValue)
                editing.set(whole, continuously: isDragging)
            }, in: range) { dragging in
                isDragging = dragging
                if !dragging { editing.endChange() }
            }
            .labelsHidden()
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(verbatim: format(value)))
        }
    }
}

extension ParameterSlider where Value == Double {
    init(
        _ title: LocalizedStringKey, _ editing: ParameterEditing<Double>, in range: ClosedRange<Double>,
        format: @escaping (Double) -> String = ParameterFormat.decimal
    ) {
        self.init(title, editing, in: range, format: format, component: { $0 }, setComponent: { $0 = $1 })
    }
}

/// How parameters' values read beside their sliders.
enum ParameterFormat {
    static func decimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    static func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    static func whole(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)))
    }

    static func degrees(_ value: Double) -> String {
        Measurement(value: value, unit: UnitAngle.degrees)
            .formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func kelvin(_ value: Double) -> String {
        Measurement(value: value, unit: UnitTemperature.kelvin)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided, numberFormatStyle: .number.precision(.fractionLength(0))))
    }

    static func stops(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
    }
}

/// A diamond that sets a keyframe at the playhead, or takes away the one
/// there: filled on a keyframe, outlined when the parameter has keyframes
/// elsewhere.
struct KeyframeButton<Value: Interpolatable>: View {
    let editing: ParameterEditing<Value>

    var body: some View {
        let isOnKeyframe = editing.parameter.hasKeyframe(at: editing.time)
        Button {
            var parameter = editing.parameter
            parameter.toggleKeyframe(at: editing.time)
            editing.change(parameter, false)
        } label: {
            Label(isOnKeyframe ? "Inspector.Keyframe.Remove" : "Inspector.Keyframe.Add",
                  systemImage: isOnKeyframe ? "diamond.fill" : "diamond")
                .labelStyle(.iconOnly)
                .foregroundStyle(editing.parameter.isAnimated ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
        }
        .buttonStyle(.borderless)
        .disabled(!editing.canKeyframe)
        .help(Text(isOnKeyframe ? "Inspector.Keyframe.Remove" : "Inspector.Keyframe.Add"))
        .contextMenu {
            // On a keyframe, how this parameter travels on from it.
            if let interpolation = editing.parameter.interpolation(at: editing.time) {
                EasingPicker(interpolation: interpolation, showsCurve: false) { interpolation, _ in
                    var parameter = editing.parameter
                    parameter.setInterpolation(interpolation, at: editing.time)
                    editing.change(parameter, false)
                }
            }
        }
    }
}
