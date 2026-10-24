import CoreGraphics
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct InterpolationTests {
    private let oneSecond = CMTime(value: 1, timescale: 1)
    private let twoSeconds = CMTime(value: 2, timescale: 1)

    @Test func blendsSizes() {
        let size = Animatable(CGSize.zero, keyframes: [
            Keyframe(time: .zero, value: CGSize(width: 0, height: 10)),
            Keyframe(time: twoSeconds, value: CGSize(width: 100, height: 30)),
        ])
        #expect(size.value(at: oneSecond) == CGSize(width: 50, height: 20))
    }

    @Test func blendsColoursChannelByChannel() {
        let colour = Animatable(RGBAColor.black, keyframes: [
            Keyframe(time: .zero, value: RGBAColor(red: 1, green: 0, blue: 0, alpha: 0)),
            Keyframe(time: twoSeconds, value: RGBAColor(red: 0, green: 1, blue: 0.5, alpha: 1)),
        ])
        #expect(colour.value(at: oneSecond) == RGBAColor(red: 0.5, green: 0.5, blue: 0.25, alpha: 0.5))
        let values = RGBValues.interpolate(from: RGBValues(0), to: RGBValues(red: 1, green: 2, blue: 4), fraction: 0.25)
        #expect(values == RGBValues(red: 0.25, green: 0.5, blue: 1))
    }
}
