import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// The other editors' built-in effects, with values as their own exports
/// write them, and what Final Cut's templates and Color Adjustments make of
/// them.
struct EffectMappingTests {
    private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
        CMTime(value: value, timescale: timescale)
    }

    private func parameters(_ values: [String: Animatable<Double>]) -> ImportedParameters {
        ImportedParameters { wanted in values.first { $0.key.lowercased() == wanted.lowercased() }?.value }
    }

    private func fcpxml(_ name: String, uid: String = "", _ values: [String: Animatable<Double>] = [:]) -> Effect.Kind? {
        EffectMapping.fcpxml(uid: uid, name: name, parameters: parameters(values), frameWidth: 1920)
    }

    private func mosaic(_ kind: Effect.Kind?) throws -> Mosaic {
        guard case .mosaic(let mosaic) = kind else { throw MappingError.wrongKind }
        return mosaic
    }

    private func correction(_ kind: Effect.Kind?) throws -> ColorCorrection {
        guard case .colorCorrection(let correction) = kind else { throw MappingError.wrongKind }
        return correction
    }

    private func equalizer(_ kind: Effect.Kind?) throws -> Equalizer {
        guard case .equalizer(let equalizer) = kind else { throw MappingError.wrongKind }
        return equalizer
    }

    private enum MappingError: Error { case wrongKind }

    // MARK: - Final Cut blur and pixellate

    @Test func readsTheGaussianAmountAsTheSliderWritesIt() throws {
        // 15.73 on the slider, as Final Cut writes it.
        let blur = try mosaic(fcpxml("Gaussian", uid: EffectMapping.fcpGaussianBlurUID, ["Amount": Animatable(0.1573)]))
        #expect(blur.style == .blur)
        #expect(abs(blur.scale.value * 1920 - 39.325) < 0.0001)
    }

    @Test func takesAGaussianWithoutAnAmountAsLeftAtFifty() throws {
        let blur = try mosaic(fcpxml("Gaussian", uid: EffectMapping.fcpGaussianBlurUID))
        #expect(abs(blur.scale.value * 1920 - 125) < 0.0001)
    }

    @Test func keepsTheGaussianKeyframes() throws {
        let amount = Animatable(0, keyframes: [Keyframe(time: .zero, value: 0), Keyframe(time: seconds(1), value: 0.5)])
        let blur = try mosaic(fcpxml("Gaussian", uid: EffectMapping.fcpGaussianBlurUID, ["Amount": amount]))
        #expect(blur.scale.keyframes.map(\.time) == [.zero, seconds(1)])
        #expect(zip(blur.scale.keyframes.map { $0.value * 1920 }, [0.0, 125]).allSatisfy { abs($0 - $1) < 0.0001 })
    }

    @Test func readsThePixellateAmountAsSquaresFromOneToAHundredPixels() throws {
        let full = try mosaic(fcpxml("Pixellate", uid: EffectMapping.fcpPixellateUID, ["Amount": Animatable(1)]))
        #expect(full.style == .pixelate)
        #expect(abs(full.scale.value * 1920 - 100) < 0.0001)
        let untouched = try mosaic(fcpxml("Pixellate", uid: EffectMapping.fcpPixellateUID))
        #expect(abs(untouched.scale.value * 1920 - 8.5933) < 0.0001)
    }

    @Test func writesTheAmountBackAsItWasRead() {
        for (style, amount) in [(Mosaic.Style.blur, 0.1573), (.pixelate, 0.0767)] {
            let kind = style == .blur
                ? fcpxml("Gaussian", uid: EffectMapping.fcpGaussianBlurUID, ["Amount": Animatable(amount)])
                : fcpxml("Pixellate", uid: EffectMapping.fcpPixellateUID, ["Amount": Animatable(amount)])
            guard case .mosaic(let mosaic) = kind else {
                Issue.record("No mosaic")
                continue
            }
            #expect(abs(EffectMapping.fcpAmount(for: style, scale: mosaic.scale.value, frameWidth: 1920) - amount) < 0.000001)
        }
    }

    // MARK: - Final Cut Color Adjustments

    @Test func findsColorAdjustmentsByItsUID() throws {
        let adjusted = try correction(fcpxml("Farbanpassungen", uid: EffectMapping.fcpColorAdjustmentsUID,
                                             ["Saturation": Animatable(50)]))
        #expect(adjusted.saturation.value == 1.5)
    }

    @Test func turnsExposureIntoAGainOnTheValuesAsShown() throws {
        let brighter = try correction(fcpxml("Color Adjustments", ["Exposure": Animatable(100)]))
        #expect(abs(brighter.gain.value.red - 1 / 0.69) < 0.0001)
        #expect(abs(brighter.lift.value.red) < 0.0001)
        #expect(brighter.exposure.value == 0)
        let darker = try correction(fcpxml("Color Adjustments", ["Exposure": Animatable(-100)]))
        #expect(abs(darker.gain.value.green - 0.69) < 0.0001)
    }

    /// Values from a real export (OpenFCPXMLKit's 29.97 sample), the black
    /// point typed past the slider's end.
    @Test func putsBlackAndWhiteWhereBlackPointAndExposureTakeThem() throws {
        let adjusted = try correction(fcpxml("Color Adjustments", [
            "Black Point": Animatable(120), "Exposure": Animatable(-19), "Contrast": Animatable(-19),
            "Saturation": Animatable(64.8),
        ]))
        let lift = adjusted.lift.value.blue, gain = adjusted.gain.value.blue
        // Black comes out at 0.3 × 1.2, white at 1 - 0.31 × 0.19.
        #expect(abs(gain * lift - 0.36) < 0.0001)
        #expect(abs(gain - 0.9411) < 0.0001)
        #expect(abs(adjusted.contrast.value - 0.943) < 0.0001)
        #expect(abs(adjusted.saturation.value - 1.648) < 0.0001)
    }

    @Test func writesSlidersFinalCutReadsBackAsTheSameLook() {
        for stops in [-0.4, -0.1, 0.2, 0.5] {
            let slider = EffectMapping.FCPColorAdjustments.exposureSlider(stops: stops)
            let gain = EffectMapping.FCPColorAdjustments.liftAndGain(blackPoint: 0, exposure: slider).gain
            #expect(abs(gain - pow(2, stops)) < 0.0001)
        }
        for contrast in [0.75, 1, 1.2, 1.4] {
            let slider = EffectMapping.FCPColorAdjustments.contrastSlider(contrast)
            #expect(abs(EffectMapping.FCPColorAdjustments.contrast(slider) - contrast) < 0.0001)
        }
        // Past the slider's ends, it's held there.
        #expect(EffectMapping.FCPColorAdjustments.contrastSlider(3) == 100)
    }

    @Test func makesContrastSteeperAsFinalCutDoes() throws {
        let more = try correction(fcpxml("Color Adjustments", ["Contrast": Animatable(100)]))
        #expect(abs(more.contrast.value - 1 / 0.7) < 0.0001)
        let less = try correction(fcpxml("Color Adjustments", ["Contrast": Animatable(-100)]))
        #expect(abs(less.contrast.value - 0.7) < 0.0001)
    }

    @Test func keyframesBlackPointAndExposureTogether() throws {
        let exposure = Animatable(0, keyframes: [Keyframe(time: .zero, value: 0), Keyframe(time: seconds(2), value: 100)])
        let blackPoint = Animatable(0, keyframes: [Keyframe(time: seconds(1), value: 100, interpolation: .hold)])
        let adjusted = try correction(fcpxml("Color Adjustments", ["Exposure": exposure, "Black Point": blackPoint]))
        #expect(adjusted.gain.keyframes.map(\.time) == [.zero, seconds(1), seconds(2)])
        #expect(adjusted.lift.keyframes.map(\.time) == [.zero, seconds(1), seconds(2)])
        // At one second the black point is up, and exposure half way.
        let lift = adjusted.lift.keyframes[1].value.red, gain = adjusted.gain.keyframes[1].value.red
        #expect(abs(gain * lift - 0.3) < 0.0001)
        // White goes up by exposure, less the room the black point takes.
        #expect(abs(gain - (0.7 / 0.845 + 0.3)) < 0.0001)
    }

    // MARK: - EQ

    @Test func bringsInTheFlatEQsChangedBands() throws {
        let eq = try equalizer(EffectMapping.fcpxmlEqualizer(mode: "flat", bands: [
            ("64 Hz", Animatable(-6)), ("1 kHz", Animatable(0)), ("4K Hz", Animatable(3)),
        ]))
        #expect(eq.bands.map(\.frequency.value) == [64, 4000])
        #expect(eq.bands.map(\.gain.value) == [-6, 3])
        #expect(eq.bands.map(\.bandwidth.value) == [1, 1])
    }

    @Test func narrowsTheBandsOfTheThirtyOneBandEQ() throws {
        let eq = try equalizer(EffectMapping.fcpxmlEqualizer(mode: nil, bands: [("40 Hz", Animatable(4))]))
        #expect(abs(eq.bands[0].bandwidth.value - 1.0 / 3) < 0.000001)
    }

    @Test func leavesTheEQsPresetsAndAFlatEQAlone() {
        #expect(EffectMapping.fcpxmlEqualizer(mode: "hum_reduction", bands: [("64 Hz", Animatable(-6))]) == nil)
        #expect(EffectMapping.fcpxmlEqualizer(mode: "flat", bands: [("64 Hz", Animatable(0))]) == nil)
    }

    @Test func readsAClipsEQFromFinalCut() throws {
        let xml = """
            <fcpxml version="1.11"><resources><format id="r1" frameDuration="1/30s" width="1920" height="1080"/>
            <asset id="a1" name="A" start="0s" duration="10s" hasAudio="1" format="r1"><media-rep kind="original-media" src="a.wav"/></asset>
            </resources><library><event><project name="P"><sequence format="r1" tcStart="0s"><spine>
            <asset-clip ref="a1" offset="0s" start="0s" duration="5s">
            <adjust-EQ mode="flat"><param name="64 Hz" key="2/1" value="-6"/><param name="8 kHz" key="2/8" value="2.5"/></adjust-EQ>
            </asset-clip></spine></sequence></project></event></library></fcpxml>
            """
        let imported = try ProjectInterchange.read(Data(xml.utf8))
        let clip = try #require(imported.project.tracks.flatMap(\.clips).first)
        let eq = try equalizer(clip.effects.first { if case .equalizer = $0.kind { true } else { false } }?.kind)
        #expect(eq.bands.map(\.frequency.value) == [64, 8000])
        #expect(eq.bands.map(\.gain.value) == [-6, 2.5])
        #expect(!imported.report.items.contains { $0.issue == .setting(name: "EQ") })
    }

    @Test func readsAParametricEQFromFinalCut7AndPremiere() throws {
        let fcp7 = try equalizer(EffectMapping.xmeml(id: "", name: "Parametric Equalizer", parameters: parameters([
            "frequency": Animatable(2500), "gain": Animatable(-4), "Q": Animatable(sqrt(2)),
        ]), frameWidth: 1920))
        #expect(fcp7.bands.count == 1)
        #expect(fcp7.bands[0].frequency.value == 2500)
        #expect(fcp7.bands[0].gain.value == -4)
        // A Q of √2 is an octave wide.
        #expect(abs(fcp7.bands[0].bandwidth.value - 1) < 0.0001)

        let premiere = try equalizer(EffectMapping.xmeml(id: "", name: "Simple Parametric EQ", parameters: parameters([
            "Center": Animatable(400), "Boost": Animatable(6),
        ]), frameWidth: 1920))
        #expect(premiere.bands[0].frequency.value == 400)
        #expect(premiere.bands[0].gain.value == 6)
    }
}
