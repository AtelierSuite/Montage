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

    @Test func followsABezierCurve() {
        // The straight line, written as a curve.
        let straight = TimingCurve(x1: 1.0 / 3, y1: 1.0 / 3, x2: 2.0 / 3, y2: 2.0 / 3)
        for t in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(abs(straight.progress(at: t) - t) < 1e-6)
        }
        // CSS's ease-in-out is symmetrical, half way at half time, slow at
        // the ends.
        let easeInOut = TimingCurve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        #expect(abs(easeInOut.progress(at: 0.5) - 0.5) < 1e-6)
        #expect(easeInOut.progress(at: 0.1) < 0.1)
        #expect(abs(easeInOut.progress(at: 0.2) + easeInOut.progress(at: 0.8) - 1) < 1e-6)
        // Control points past 1 overshoot.
        let overshoot = TimingCurve(x1: 0.3, y1: 1.6, x2: 0.7, y2: 1.6)
        #expect(overshoot.progress(at: 0.5) > 1)

        let value = Animatable(0.0, keyframes: [
            Keyframe(time: .zero, value: 0, interpolation: .bezier(easeInOut)),
            Keyframe(time: twoSeconds, value: 10),
        ])
        #expect(abs(value.value(at: oneSecond) - 5) < 1e-5)
        #expect(value.value(at: CMTime(value: 1, timescale: 5)) < 1)
    }

    @Test func writesNamedInterpolationsByName() throws {
        let keyframes = [
            Keyframe(time: .zero, value: 1.0, interpolation: .easeIn),
            Keyframe(time: oneSecond, value: 2.0, interpolation: .bezier(TimingCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4))),
        ]
        let data = try JSONEncoder().encode(keyframes)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("\"easeIn\""))
        #expect(try JSONDecoder().decode([Keyframe<Double>].self, from: data) == keyframes)
    }
}
