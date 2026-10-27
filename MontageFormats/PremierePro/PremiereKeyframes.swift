import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine

/// A component parameter's value and keyframes, as Premiere writes them.
///
///     <VideoComponentParam ObjectID="…">
///         <Name>Opacity</Name>
///         <StartKeyframe>-91445760000000000,100.,0,0,0,0,0,0</StartKeyframe>
///         <IsTimeVarying>true</IsTimeVarying>
///         <Keyframes>127008000000,25.,0,0,…;381024000000,75.,4,0,…;</Keyframes>
///     </VideoComponentParam>
///
/// A keyframe is `ticks,value,interpolation,…` with tangents after, and the
/// keyframes are ended by semicolons. `StartKeyframe` holds the value when
/// the parameter isn't keyframed, at a time before any clip. Values are
/// numbers ("100."), points ("0.5:0.5", across and down as fractions) or
/// flags ("true"). Audio parameters drop `IsTimeVarying` once keyframed,
/// so keyframes are taken as on wherever there are any, unless the flag
/// says they're off.
enum PremiereKeyframes {
    /// The parameter as an `Animatable`, its keyframes timed by `toClip`
    /// from their ticks, or nil if it has no value that `parse` reads.
    static func animatable<Value>(
        _ parameter: MarkupElement, toClip: (Int64) -> CMTime, _ parse: (Substring) -> Value?
    ) -> Animatable<Value>? {
        let keyframes = isAnimated(parameter) ? entries(parameter.child("Keyframes")?.text).compactMap { fields -> Keyframe<Value>? in
            guard let ticks = Int64(fields[0]), let value = parse(fields[1]) else { return nil }
            let mode = fields.count > 2 ? Int(fields[2]) ?? 0 : 0
            return Keyframe(time: toClip(ticks), value: value, interpolation: interpolation(mode))
        } : []
        let start = entries(parameter.child("StartKeyframe")?.text).first.flatMap { parse($0[1]) }
        let current = parameter.child("CurrentValue").flatMap { parse(Substring($0.text)) }
        guard let value = keyframes.first?.value ?? start ?? current else { return nil }
        return Animatable(value, keyframes: keyframes)
    }

    /// Whether the parameter changes over time.
    static func isAnimated(_ parameter: MarkupElement) -> Bool {
        parameter.child("IsTimeVarying")?.text != "false" && !entries(parameter.child("Keyframes")?.text).isEmpty
    }

    /// The parameter's value as written, unparsed, for a parameter kept as
    /// it was.
    static func value(of parameter: MarkupElement) -> String? {
        entries(parameter.child("StartKeyframe")?.text).first.map { String($0[1]) }
            ?? parameter.child("CurrentValue")?.text
    }

    static func point(_ field: Substring) -> CGPoint? {
        let parts = field.split(separator: ":")
        guard parts.count == 2, let x = PremiereProject.number(parts[0]), let y = PremiereProject.number(parts[1]) else {
            return nil
        }
        return CGPoint(x: x, y: y)
    }

    /// Premiere's interpolations, by the numbers its scripting gives them:
    /// linear, three eases it no longer offers, hold, and Bézier, whose
    /// curve is taken as easing in and out.
    static func interpolation(_ mode: Int) -> Interpolation {
        switch mode {
        case 1: .easeIn
        case 2: .easeOut
        case 3, 5: .easeInOut
        case 4: .hold
        default: .linear
        }
    }

    /// The keyframes in a list, each split into its fields, which are at
    /// least a time and a value.
    private static func entries(_ text: String?) -> [[Substring]] {
        (text ?? "").split(separator: ";").map { $0.split(separator: ",", omittingEmptySubsequences: false) }
            .filter { $0.count >= 2 && !$0[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { fields in fields.map { Substring($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
    }
}
