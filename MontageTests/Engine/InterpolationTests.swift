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
}
