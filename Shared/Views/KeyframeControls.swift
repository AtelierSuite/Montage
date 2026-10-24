import CoreMedia
import MontageEngine
import SwiftUI

/// The clip's keyframes in the inspector: buttons to move the playhead to
/// the one before or after, and, on one, how its parameters travel on from
/// there, and a button to take it away.
struct KeyframeControls: View {
    @Environment(ProjectEditor.self) private var editor
    let clip: Clip

    var body: some View {
        let time = editor.keyframeTimeAtPlayhead(in: clip)
        Section {
            HStack {
                Button("Inspector.Keyframes.Previous", systemImage: "chevron.left") { editor.goToPreviousKeyframe() }
                    .disabled(editor.previousKeyframeTime == nil)
                    .help(Text("Inspector.Keyframes.Previous"))
                Spacer()
                Text(verbatim: "\(clip.keyframeTimes.count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(Text(verbatim: String(
                        format: String(localized: "Inspector.Keyframes.Count"), clip.keyframeTimes.count.formatted()
                    )))
                Image(systemName: "diamond")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Spacer()
                Button("Inspector.Keyframes.Next", systemImage: "chevron.right") { editor.goToNextKeyframe() }
                    .disabled(editor.nextKeyframeTime == nil)
                    .help(Text("Inspector.Keyframes.Next"))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            if let time {
                EasingPicker(interpolation: clip.keyframeInterpolation(at: time)) { interpolation, continuously in
                    editor.setKeyframeInterpolation(interpolation, at: time, ofClip: clip.id, continuously: continuously)
                } endChange: {
                    editor.endGesture()
                }
                Button("Inspector.Keyframes.Remove", systemImage: "trash", role: .destructive) {
                    editor.removeKeyframes(at: time, ofClip: clip.id)
                }
                .buttonStyle(.borderless)
            }
        } header: {
            Text("Inspector.Keyframes")
        } footer: {
            if clip.keyframeTimes.isEmpty {
                Text("Inspector.Keyframes.Empty")
            } else if time == nil {
                Text("Inspector.Keyframes.None")
            }
        }
    }
}

/// How a keyframe travels on to the next, picked by name, with the control
/// points of a curve of its own.
struct EasingPicker: View {
    /// The keyframes' way, or nil when several keyframes differ.
    let interpolation: Interpolation?
    let change: (_ interpolation: Interpolation, _ continuously: Bool) -> Void
    var endChange: () -> Void = {}

    var body: some View {
        Picker("Inspector.Keyframes.Easing", selection: Binding {
            interpolation.map(EasingChoice.init)
        } set: { choice in
            if let choice { change(choice.interpolation(keeping: interpolation), false) }
        }) {
            if interpolation == nil {
                Text("Inspector.Keyframes.Easing.Mixed").tag(EasingChoice?.none)
            }
            ForEach(EasingChoice.allCases, id: \.self) { choice in
                Text(choice.title).tag(EasingChoice?.some(choice))
            }
        }
        if case .bezier(let curve) = interpolation {
            CurveSlider("Inspector.Keyframes.Curve.X1", value: curve.x1, in: 0...1) { set(curve, x1: $0, continuously: $1) }
            CurveSlider("Inspector.Keyframes.Curve.Y1", value: curve.y1, in: -1...2) { set(curve, y1: $0, continuously: $1) }
            CurveSlider("Inspector.Keyframes.Curve.X2", value: curve.x2, in: 0...1) { set(curve, x2: $0, continuously: $1) }
            CurveSlider("Inspector.Keyframes.Curve.Y2", value: curve.y2, in: -1...2) { set(curve, y2: $0, continuously: $1) }
        }
    }

    private func set(
        _ curve: TimingCurve, x1: Double? = nil, y1: Double? = nil, x2: Double? = nil, y2: Double? = nil, continuously: Bool
    ) {
        if !continuously {
            endChange()
            return
        }
        change(.bezier(TimingCurve(x1: x1 ?? curve.x1, y1: y1 ?? curve.y1, x2: x2 ?? curve.x2, y2: y2 ?? curve.y2)), true)
    }
}

/// One of a custom curve's control point coordinates, on a slider.
private struct CurveSlider: View {
    let title: LocalizedStringKey
    let value: Double
    let range: ClosedRange<Double>
    /// The new value, and whether the drag goes on: false once it ends.
    let change: (Double, Bool) -> Void

    init(_ title: LocalizedStringKey, value: Double, in range: ClosedRange<Double>, change: @escaping (Double, Bool) -> Void) {
        self.title = title
        self.value = value
        self.range = range
        self.change = change
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(verbatim: ParameterFormat.decimal(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding { value } set: { change($0, true) }, in: range) { editing in
                if !editing { change(value, false) }
            }
            .labelsHidden()
            .accessibilityLabel(Text(title))
        }
    }
}

/// The ways a keyframe can travel, as the easing picker lists them.
enum EasingChoice: CaseIterable, Hashable {
    case hold, linear, easeIn, easeOut, easeInOut, custom

    init(_ interpolation: Interpolation) {
        switch interpolation {
        case .hold: self = .hold
        case .linear: self = .linear
        case .easeIn: self = .easeIn
        case .easeOut: self = .easeOut
        case .easeInOut: self = .easeInOut
        case .bezier: self = .custom
        }
    }

    /// The way it stands for; a custom curve keeps the one already there,
    /// or starts as an ease in and out.
    func interpolation(keeping current: Interpolation?) -> Interpolation {
        switch self {
        case .hold: .hold
        case .linear: .linear
        case .easeIn: .easeIn
        case .easeOut: .easeOut
        case .easeInOut: .easeInOut
        case .custom:
            if case .bezier(let curve) = current { .bezier(curve) } else { .bezier(TimingCurve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)) }
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .hold: "Interpolation.Hold"
        case .linear: "Interpolation.Linear"
        case .easeIn: "Interpolation.EaseIn"
        case .easeOut: "Interpolation.EaseOut"
        case .easeInOut: "Interpolation.EaseInOut"
        case .custom: "Interpolation.Custom"
        }
    }
}
