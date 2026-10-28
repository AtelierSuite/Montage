import CoreMedia
import Foundation
import MontageEngine

/// An effect's parameters as an importer read them, for the mapping to pick
/// the ones it understands out of.
struct ImportedParameters {
    /// A parameter's value as a number, and its keyframes as Montage times
    /// on the clip, or nil if the effect has no such parameter. Names are
    /// compared ignoring case.
    var number: (_ name: String) -> Animatable<Double>?

    /// The parameter under the first of the names it has.
    func number(_ names: String...) -> Animatable<Double>? {
        names.lazy.compactMap { number($0) }.first
    }
}

/// The other editors' built-in effects that line up with Montage's own.
/// Anything not mapped here comes in as an `UnsupportedEffect`.
enum EffectMapping {
    /// The UID Montage's own effects are written under, followed by the
    /// effect's type, for effects Final Cut has nothing to match. The effect
    /// itself goes in the filter's data, as Montage saves it, so it comes
    /// back exactly.
    static let montageUIDPrefix = "com.tsubuzaki.Montage.effect."

    /// One of Montage's effects as Montage writes it into a filter's data.
    static func montageData(for kind: Effect.Kind) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(kind))?.base64EncodedString()
    }

    /// The effect Montage wrote into a filter's data.
    static func montageEffect(fromData data: String) -> Effect.Kind? {
        guard let json = Data(base64Encoded: data.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return try? JSONDecoder().decode(Effect.Kind.self, from: json)
    }

    /// Final Cut's built-in Motion effects, by the end of their UIDs, which
    /// begin with an install path written as "…".
    static let fcpGaussianBlurUID = ".../Effects.localized/Blur.localized/Gaussian.localized/Gaussian.moef"
    static let fcpPixellateUID = ".../Effects.localized/Stylize.localized/Pixellate.localized/Pixellate.moef"

    /// A Final Cut effect as one of Montage's, if there's a match.
    /// `frameWidth` turns sizes in pixels into fractions of the frame.
    static func fcpxml(uid: String, name: String, parameters: ImportedParameters, frameWidth: Double) -> Effect.Kind? {
        let lowerName = name.lowercased()
        if uid.hasSuffix("/Gaussian.moef") || lowerName == "gaussian blur" || lowerName == "gaussian" {
            return mosaic(.blur, amount: parameters.number("Amount"), frameWidth: frameWidth)
        }
        if uid.hasSuffix("/Pixellate.moef") || lowerName == "pixellate" || lowerName == "pixelate" {
            return mosaic(.pixelate, amount: parameters.number("Amount"), frameWidth: frameWidth)
        }
        if lowerName == "color adjustments" {
            return colorAdjustments(parameters)
        }
        if lowerName == "gain" {
            guard let decibels = parameters.number("Gain") else { return nil }
            var gain = Gain()
            gain.decibels = decibels
            return .gain(gain)
        }
        return nil
    }

    /// A Final Cut 7 XML effect, as Premiere and Final Cut 7 write them, as
    /// one of Montage's, if there's a match. The clip settings Final Cut 7
    /// writes as effects (motion, opacity, levels and pan) aren't effects in
    /// Montage, and are read by the importer itself.
    static func xmeml(id: String, name: String, parameters: ImportedParameters, frameWidth: Double) -> Effect.Kind? {
        switch (id.lowercased(), name.lowercased()) {
        case ("gaussianblur", _), (_, "gaussian blur"):
            // Premiere's blurriness is in pixels, as Final Cut's amount is.
            return mosaic(.blur, amount: parameters.number("blurriness", "radius", "Blurriness"), frameWidth: frameWidth)
        case ("mosaic", _), (_, "mosaic"):
            // Blocks across the frame, rather than a block's size.
            var mosaic = Mosaic()
            mosaic.style = .pixelate
            if let blocks = parameters.number("horizontalblocks", "Horizontal Blocks"), blocks.value > 0 {
                mosaic.scale = Animatable(1 / blocks.value)
            }
            return .mosaic(mosaic)
        case ("brightness", _), (_, "brightness & contrast"):
            var correction = ColorCorrection()
            if let contrast = parameters.number("contrast", "Contrast") {
                correction.contrast = contrast.mapped { 1 + $0 / 100 }
            }
            guard correction.contrast.isAnimated || correction.contrast.value != 1 else { return nil }
            return .colorCorrection(correction)
        default:
            return nil
        }
    }

    // MARK: - Mapped

    private static func mosaic(_ style: Mosaic.Style, amount: Animatable<Double>?, frameWidth: Double) -> Effect.Kind {
        var mosaic = Mosaic()
        mosaic.style = style
        if let amount, frameWidth > 0 {
            mosaic.scale = amount.mapped { $0 / frameWidth }
        }
        return .mosaic(mosaic)
    }

    /// Final Cut's Color Adjustments, whose sliders run from -100 to 100
    /// with 0 leaving the picture as it is. Exposure is taken as two stops
    /// either way at the ends, and contrast and saturation as doubling.
    private static func colorAdjustments(_ parameters: ImportedParameters) -> Effect.Kind {
        var correction = ColorCorrection()
        if let exposure = parameters.number("Exposure") { correction.exposure = exposure.mapped { $0 / 50 } }
        if let contrast = parameters.number("Contrast") { correction.contrast = contrast.mapped { 1 + $0 / 100 } }
        if let saturation = parameters.number("Saturation") { correction.saturation = saturation.mapped { 1 + $0 / 100 } }
        return .colorCorrection(correction)
    }
}

extension Animatable {
    /// The same parameter with every value, and every keyframe's, changed.
    func mapped(_ transform: (Value) -> Value) -> Animatable<Value> {
        Animatable(transform(value), keyframes: keyframes.map {
            Keyframe(time: $0.time, value: transform($0.value), interpolation: $0.interpolation)
        })
    }
}
