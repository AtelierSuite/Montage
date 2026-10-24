import CoreImage
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct UnsupportedEffectTests {
    private let effect = Effect(isEnabled: false, .unsupported(UnsupportedEffect(
        format: "fcpxml", identifier: "com.example.glow", name: "Glow", isVideo: true,
        parameters: [.init(name: "Radius", key: "1/2", value: "12", isAnimated: true)],
        original: #"<filter-video ref="r9" name="Glow"/>"#
    )))

    @Test func roundTripsWithItsParameters() throws {
        let data = try JSONEncoder().encode(effect)
        #expect(String(decoding: data, as: UTF8.self).contains(#""type":"unsupported""#))
        #expect(try JSONDecoder().decode(Effect.self, from: data) == effect)
    }

    @Test func sidesWithThePictureOrSoundItCameFrom() {
        #expect(effect.kind.isVideo)
        let audio = Effect.Kind.unsupported(UnsupportedEffect(format: "xmeml", identifier: "x", name: "X", isVideo: false))
        #expect(!audio.isVideo)
        #expect(!audio.hasTail)
    }

    @Test func leavesThePictureAsItIsEvenTurnedOn() {
        var on = effect
        on.isEnabled = true
        let image = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let context = VideoEffectContext(renderSize: CGSize(width: 4, height: 4), clipTime: .zero)
        #expect(on.apply(to: image, in: context) === image)
    }

    @Test func neverRunsInAnAudioTap() {
        let sound = Effect(.unsupported(UnsupportedEffect(format: "xmeml", identifier: "x", name: "X", isVideo: false)))
        var clip = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))
        clip.effects = [sound]
        #expect(!clip.hasAudioEffects)
        #expect(clip.audioEffectLayout.units.isEmpty)
        clip.effects.append(Effect(.gain(Gain())))
        #expect(clip.audioEffectLayout.units.map(\.effectID) == [clip.effects[1].id])
    }
}
