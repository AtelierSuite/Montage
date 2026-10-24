import CoreGraphics
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct EffectModelTests {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    @Test func readsAnEffectSavedWithoutAMask() throws {
        let effect = try decode(Effect.self, #"""
            {"id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "isEnabled": true,
             "kind": {"type": "mosaic", "parameters": {"style": "blur", "scale": {"value": 0.05}}}}
            """#)
        #expect(effect.mask == nil)
        var mosaic = Mosaic()
        mosaic.style = .blur
        mosaic.scale = Animatable(0.05)
        #expect(effect.kind == .mosaic(mosaic))
    }

    @Test func keepsAnEffectsMask() throws {
        let effect = Effect(.mosaic(Mosaic()), mask: Mask(.ellipse, feather: 0.02, isInverted: true))
        #expect(try JSONDecoder().decode(Effect.self, from: JSONEncoder().encode(effect)) == effect)
    }

    @Test func readsAColorCorrectionSavedBeforeItsNewerAdjustments() throws {
        let correction = try decode(ColorCorrection.self, #"""
            {"exposure": {"value": 0.5}, "contrast": {"value": 1.2}, "saturation": {"value": 0.8},
             "temperature": {"value": 5000}, "tint": {"value": 10}}
            """#)
        #expect(correction.exposure.value == 0.5)
        #expect(correction.temperature.value == 5000)
        #expect(correction.brightness.value == 0)
        #expect(correction.gamma.value == RGBValues(1))
        #expect(correction.lut == nil)
    }

    @Test func keepsALookUpTable() throws {
        var correction = ColorCorrection()
        correction.lut = .identity(dimension: 4, name: "Look")
        correction.lift = Animatable(RGBValues(red: 0.1, green: 0, blue: -0.1))
        let read = try JSONDecoder().decode(ColorCorrection.self, from: JSONEncoder().encode(correction))
        #expect(read == correction)
        #expect(read.lut?.dimension == 4)
    }

    @Test func refusesATableOfTheWrongSize() {
        #expect(ColorLUT(name: "", dimension: 4, data: Data(count: 100)) == nil)
        #expect(ColorLUT(name: "", dimension: 2, data: Data(count: 2 * 2 * 2 * 16)) != nil)
    }

    @Test func readsAMosaicSavedBeforeItsStrengthAndColours() throws {
        let mosaic = try decode(Mosaic.self, #"{"style": "checkerboard", "scale": {"value": 0.1}}"#)
        #expect(mosaic.style == .checkerboard)
        #expect(mosaic.strength.value == 1)
        #expect(mosaic.firstColor.value == .black)
        var keyframed = Mosaic(style: .pixelate)
        keyframed.strength.setKeyframe(Keyframe(time: .zero, value: 0.5))
        keyframed.secondColor = Animatable(RGBAColor(red: 1, green: 0, blue: 0))
        #expect(try JSONDecoder().decode(Mosaic.self, from: JSONEncoder().encode(keyframed)) == keyframed)
    }
}
