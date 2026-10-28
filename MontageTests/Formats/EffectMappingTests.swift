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
}
