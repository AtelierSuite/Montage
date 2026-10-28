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
}
