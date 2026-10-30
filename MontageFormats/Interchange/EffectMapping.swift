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
    /// Final Cut's Color Adjustments, an FxPlug filter it has built in.
    static let fcpColorAdjustmentsUID = "FxPlug:7E2022A5-202B-4EEB-A311-AC2B585D01B0"

    /// The data key a filter of Final Cut's holds Montage's own copy of
    /// the effect under, as Montage saves it, so it comes back exactly
    /// with what Final Cut's filter has no setting for.
    static let montageDataKey = "com.tsubuzaki.Montage.effect"

    /// The settings Final Cut keeps in a Color Adjustments filter's
    /// `effectConfig` data: the plug-in's version, archived.
    static var fcpColorAdjustmentsConfig: String {
        let config = NSMutableDictionary(dictionary: ["pluginVersion": 2])
        let data = try? NSKeyedArchiver.archivedData(withRootObject: config, requiringSecureCoding: false)
        return data?.base64EncodedString() ?? ""
    }

    /// The Color Adjustments sliders a correction lines up with: their
    /// names, FxPlug parameter keys and values, on the scale Final Cut
    /// works them out on, as `colorAdjustments` reads them back. Values
    /// past the sliders' ends are held at them.
    static func fcpColorAdjustments(for correction: ColorCorrection) -> [(name: String, key: String, value: Animatable<Double>)] {
        let slider: (Double) -> Double = { (min(100, max(-100, $0)) * 100).rounded() / 100 }
        return [
            ("Exposure", "3", correction.exposure.mapped { slider(FCPColorAdjustments.exposureSlider(stops: $0)) }),
            ("Contrast", "17", correction.contrast.mapped { slider(FCPColorAdjustments.contrastSlider($0)) }),
            ("Saturation", "16", correction.saturation.mapped { slider(($0 - 1) * 100) }),
        ]
    }

    /// A Final Cut effect as one of Montage's, if there's a match.
    /// `frameWidth` turns sizes in pixels into fractions of the frame.
    static func fcpxml(uid: String, name: String, parameters: ImportedParameters, frameWidth: Double) -> Effect.Kind? {
        let lowerName = name.lowercased()
        if uid.hasSuffix("/Gaussian.moef") || lowerName == "gaussian blur" || lowerName == "gaussian" {
            let amount = parameters.number("Amount") ?? Animatable(FCPGaussian.defaultAmount)
            return mosaic(.blur, pixels: amount.mapped(FCPGaussian.radius(amount:)), frameWidth: frameWidth)
        }
        if uid.hasSuffix("/Pixellate.moef") || lowerName == "pixellate" || lowerName == "pixelate" {
            let amount = parameters.number("Amount") ?? Animatable(FCPPixellate.defaultAmount)
            return mosaic(.pixelate, pixels: amount.mapped(FCPPixellate.size(amount:)), frameWidth: frameWidth)
        }
        if uid == fcpColorAdjustmentsUID || lowerName == "color adjustments" {
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

    /// Final Cut's Equalization, from a clip's audio settings: a graphic EQ
    /// of 10 bands an octave apart, or 31 a third of an octave apart, each
    /// of which is a peaking band like Montage's. Its presets (Voice
    /// Enhance, Hum Reduction and so on) aren't written out band by band,
    /// so only the flat EQ, with the bands it changes, is brought in.
    static func fcpxmlEqualizer(mode: String?, bands: [(name: String, gain: Animatable<Double>)]) -> Effect.Kind? {
        guard (mode ?? "flat").lowercased() == "flat" else { return nil }
        let changed = bands.compactMap { band -> (frequency: Double, gain: Animatable<Double>)? in
            guard let frequency = frequency(named: band.name), band.gain.isAnimated || band.gain.value != 0 else { return nil }
            return (frequency, band.gain)
        }
        guard !changed.isEmpty else { return nil }
        // A band that isn't one of the 10 means the 31.
        let isThirds = changed.contains { band in !graphicOctaveBands.contains { abs($0 - band.frequency) < 1 } }
        var equalizer = Equalizer()
        equalizer.bands = changed.sorted { $0.frequency < $1.frequency }.map { changed in
            var band = Equalizer.Band(frequency: changed.frequency, bandwidth: isThirds ? 1.0 / 3 : 1)
            band.gain = changed.gain
            return band
        }
        return .equalizer(equalizer)
    }

    /// The 10-band graphic EQ's bands, in hertz.
    static let graphicOctaveBands: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// A band's frequency from its name, such as "64 Hz" or "1.2 kHz".
    static func frequency(named name: String) -> Double? {
        let lower = name.lowercased().replacingOccurrences(of: " ", with: "")
        guard lower.hasSuffix("hz") else { return nil }
        var number = String(lower.dropLast(2))
        var scale = 1.0
        if number.hasSuffix("k") {
            number.removeLast()
            scale = 1000
        }
        guard let value = Double(number), value > 0 else { return nil }
        return value * scale
    }

    /// A peaking band's width in octaves for its Q.
    static func octaves(q: Double) -> Double {
        guard q > 0 else { return Equalizer.Band(frequency: 1000).bandwidth.value }
        return 2 / log(2) * asinh(1 / (2 * q))
    }

    /// The Amount Final Cut's Gaussian or Pixellate is written with for a
    /// mosaic, the other way from `fcpxml`.
    static func fcpAmount(for style: Mosaic.Style, scale: Double, frameWidth: Double) -> Double {
        let pixels = scale * frameWidth
        return style == .blur ? FCPGaussian.amount(radius: pixels) : FCPPixellate.amount(size: pixels)
    }

    /// Final Cut's Gaussian, as its template rigs it. The Amount slider shows
    /// 0 to 100 but is written from 0 to 1, 0.5 when it's left alone. It
    /// sets the amount of a hidden blur from 0 to 250 pixels, which the blur
    /// that's seen is linked to, times a Blur Boost of 1 (the template's
    /// clamp to 64 is off, as its link applies at all values).
    enum FCPGaussian {
        static let defaultAmount = 0.5
        static let pixelsAtFull = 250.0

        static func radius(amount: Double) -> Double { max(0, amount) * pixelsAtFull }
        static func amount(radius: Double) -> Double { radius / pixelsAtFull }
    }

    /// Final Cut's Pixellate, as its template rigs it: the Amount slider,
    /// written from 0 to 1 as the Gaussian's is, sets squares from 1 to 100
    /// pixels across, about 8.6 when it's left alone.
    enum FCPPixellate {
        static let defaultAmount = 0.0767

        static func size(amount: Double) -> Double { 1 + 99 * max(0, amount) }
        static func amount(size: Double) -> Double { max(0, size - 1) / 99 }
    }

    /// A Final Cut 7 XML effect, as Premiere and Final Cut 7 write them, as
    /// one of Montage's, if there's a match. The clip settings Final Cut 7
    /// writes as effects (motion, opacity, levels and pan) aren't effects in
    /// Montage, and are read by the importer itself.
    static func xmeml(id: String, name: String, parameters: ImportedParameters, frameWidth: Double) -> Effect.Kind? {
        switch (id.lowercased(), name.lowercased()) {
        case ("gaussianblur", _), (_, "gaussian blur"):
            // Premiere's blurriness is in pixels.
            return mosaic(.blur, amount: parameters.number("blurriness", "radius", "Blurriness"), frameWidth: frameWidth)
        case ("mosaic", _), (_, "mosaic"):
            // Blocks across the frame, rather than a block's size.
            var mosaic = Mosaic()
            mosaic.style = .pixelate
            if let blocks = parameters.number("horizontalblocks", "Horizontal Blocks") {
                mosaic.scale = blocks.mapped { 1 / max($0, 1) }
            }
            return .mosaic(mosaic)
        case ("brightness", _), (_, "brightness & contrast"):
            var correction = ColorCorrection()
            if let contrast = parameters.number("contrast", "Contrast") {
                correction.contrast = contrast.mapped { 1 + $0 / 100 }
            }
            guard correction.contrast.isAnimated || correction.contrast.value != 1 else { return nil }
            return .colorCorrection(correction)
        case ("parametriceq", _), (_, "parametric equalizer"), (_, "parametric eq"), (_, "simple parametric eq"):
            // Final Cut 7's Parametric Equalizer and Premiere's Simple
            // Parametric EQ: one peaking band, as each of Montage's is.
            guard let frequency = parameters.number("frequency", "center"),
                  let gain = parameters.number("gain", "boost") else { return nil }
            var band = Equalizer.Band(frequency: frequency.value)
            band.frequency = frequency
            band.gain = gain
            if let q = parameters.number("q") { band.bandwidth = q.mapped(octaves(q:)) }
            var equalizer = Equalizer()
            equalizer.bands = [band]
            return .equalizer(equalizer)
        default:
            return nil
        }
    }

    // MARK: - Mapped

    private static func mosaic(_ style: Mosaic.Style, amount: Animatable<Double>?, frameWidth: Double) -> Effect.Kind {
        guard let amount else {
            var mosaic = Mosaic()
            mosaic.style = style
            return .mosaic(mosaic)
        }
        return mosaic(style, pixels: amount, frameWidth: frameWidth)
    }

    private static func mosaic(_ style: Mosaic.Style, pixels: Animatable<Double>, frameWidth: Double) -> Effect.Kind {
        var mosaic = Mosaic()
        mosaic.style = style
        if frameWidth > 0 {
            mosaic.scale = pixels.mapped { $0 / frameWidth }
        }
        return .mosaic(mosaic)
    }

    /// Final Cut's Color Adjustments, as it works them out: each slider runs
    /// from -100 to 100 (and to 200 typed in), and is taken as a hundredth
    /// of that. Black Point and Exposure become a lift and gain on the values
    /// as shown, as Montage's lift and gain are; Contrast is another lift and
    /// gain, which Montage's contrast stands in for, pivoting on the middle
    /// grey; and Saturation scales the colour, 1 being unchanged. Brightness,
    /// Shadows, Highlights and the warmth and tint of each go through curves
    /// of Final Cut's own and aren't brought in.
    private static func colorAdjustments(_ parameters: ImportedParameters) -> Effect.Kind {
        var correction = ColorCorrection()
        let blackPoint = parameters.number("Black Point") ?? Animatable(0)
        let exposure = parameters.number("Exposure") ?? Animatable(0)
        if blackPoint.isAnimated || exposure.isAnimated || blackPoint.value != 0 || exposure.value != 0 {
            let levels = { (blackPoint: Double, exposure: Double) in
                FCPColorAdjustments.liftAndGain(blackPoint: blackPoint, exposure: exposure)
            }
            correction.lift = combined(blackPoint, exposure) { levels($0, $1).lift }.mappedToRGB
            correction.gain = combined(blackPoint, exposure) { levels($0, $1).gain }.mappedToRGB
        }
        if let contrast = parameters.number("Contrast") {
            correction.contrast = contrast.mapped(FCPColorAdjustments.contrast)
        }
        if let saturation = parameters.number("Saturation") {
            correction.saturation = saturation.mapped { max(0, 1 + $0 / 100) }
        }
        return .colorCorrection(correction)
    }

    /// The sums Final Cut's Color Adjustments does with its sliders.
    enum FCPColorAdjustments {
        /// How far each slider's hundredth moves the black point, the top
        /// of the range, and either end for contrast.
        static let blackPointScale = 0.3
        static let exposureScale = 0.31
        static let contrastScale = 0.15

        /// The lift and gain that put black and white where the black point
        /// and exposure take them, with contrast moving both ends apart: a
        /// value comes out as gain × (value + lift × (1 - value)).
        static func liftAndGain(blackPoint: Double, exposure: Double, contrast: Double = 0) -> (lift: Double, gain: Double) {
            let contrast = contrast / 100 * contrastScale
            let low = blackPoint / 100 * blackPointScale - contrast
            let high = 1 + exposure / 100 * exposureScale + contrast
            let crushed = max(-low, 0), raised = max(low, 0)
            let top = max(min(high, 1), raised + 0.0001)
            let base = max(high < 1 ? 1 : 2 - high, crushed + 0.0001)
            let slope = (top - raised) / (base - crushed)
            let offset = raised - crushed * slope
            let gain = slope + offset
            guard gain > 0 else { return (0, 0) }
            return (min(max(offset / gain + 1, 0), 2) - 1, min(gain, 200))
        }

        /// Contrast as how much steeper the middle of the range is made, about
        /// 1.43 at 100 and 0.7 at -100.
        static func contrast(_ value: Double) -> Double {
            let (lift, gain) = liftAndGain(blackPoint: 0, exposure: 0, contrast: value)
            return max(0, gain * (1 - lift))
        }

        /// The Exposure slider whose gain is closest to an exposure in stops:
        /// above 0 it raises white by a stretch, below 0 it lowers it.
        static func exposureSlider(stops: Double) -> Double {
            let gain = pow(2, stops)
            let scale = exposureScale / 100
            return gain >= 1 ? (1 - 1 / gain) / scale : (gain - 1) / scale
        }

        /// The Contrast slider that makes `contrast`, found by halving the
        /// range it can be in, as `contrast` only ever rises with it.
        static func contrastSlider(_ value: Double) -> Double {
            var low = -100.0, high = 100.0
            guard value > contrast(low) else { return low }
            guard value < contrast(high) else { return high }
            for _ in 0..<50 {
                let middle = (low + high) / 2
                if contrast(middle) < value { low = middle } else { high = middle }
            }
            return (low + high) / 2
        }
    }

    /// Two parameters put together into one, at each of their keyframes.
    private static func combined(
        _ first: Animatable<Double>, _ second: Animatable<Double>, _ combine: (Double, Double) -> Double
    ) -> Animatable<Double> {
        guard first.isAnimated || second.isAnimated else { return Animatable(combine(first.value, second.value)) }
        var keyframes: [Keyframe<Double>] = []
        let times = (first.keyframes + second.keyframes).map(\.time).sorted()
        for (index, time) in times.enumerated() where index == 0 || times[index - 1] != time {
            let interpolation = (first.keyframes.first { $0.time == time } ?? second.keyframes.first { $0.time == time })!.interpolation
            keyframes.append(Keyframe(time: time, value: combine(first.value(at: time), second.value(at: time)),
                                      interpolation: interpolation))
        }
        return Animatable(keyframes[0].value, keyframes: keyframes)
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

private extension Animatable where Value == Double {
    /// The same amount for every channel.
    var mappedToRGB: Animatable<RGBValues> {
        Animatable<RGBValues>(RGBValues(value), keyframes: keyframes.map {
            Keyframe(time: $0.time, value: RGBValues($0.value), interpolation: $0.interpolation)
        })
    }
}
