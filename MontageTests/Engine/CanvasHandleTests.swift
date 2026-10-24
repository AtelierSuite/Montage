import CoreGraphics
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

private func approximately(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 1e-6) -> Bool {
    abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
}

private func approximately(_ a: Double, _ b: Double, within tolerance: Double = 1e-6) -> Bool {
    abs(a - b) < tolerance
}

private func s(_ seconds: Double) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

struct TransformHandleTests {
    private let renderSize = CGSize(width: 1920, height: 1080)

    @Test func movesByTheDrag() {
        var transform = ClipTransform()
        transform.drag(.move, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 292, y: 208), renderSize: renderSize, at: .zero)
        #expect(approximately(transform.position.value, CGPoint(x: 0.6, y: 0.6)))
        #expect(!transform.position.isAnimated)
    }

    @Test func scalesByDistanceFromTheCentre() {
        var transform = ClipTransform()
        transform.drag(.scale, from: CGPoint(x: 1920, y: 1080), to: CGPoint(x: 1440, y: 810), renderSize: renderSize, at: .zero)
        #expect(approximately(transform.scale.value, 0.5))
    }

    @Test func keepsScaleWithinItsRange() {
        var transform = ClipTransform()
        transform.drag(.scale, from: CGPoint(x: 1920, y: 1080), to: CGPoint(x: 960, y: 540), renderSize: renderSize, at: .zero)
        #expect(transform.scale.value == ClipTransform.scaleRange.lowerBound)
    }

    @Test func rotatesByTheAngleAboutTheCentre() {
        var transform = ClipTransform()
        transform.rotation = Animatable(10)
        // From straight above the centre to straight right of it: a quarter
        // turn clockwise.
        transform.drag(.rotate, from: CGPoint(x: 960, y: 100), to: CGPoint(x: 1500, y: 540), renderSize: renderSize, at: .zero)
        #expect(approximately(transform.rotation.value, 100))
    }

    @Test func rotatesTheShortWayRound() {
        #expect(approximately(CanvasMath.turn(from: CGPoint(x: -1, y: -0.01), to: CGPoint(x: -1, y: 0.01), about: .zero)!, -1.1459, within: 1e-3))
        #expect(CanvasMath.turn(from: .zero, to: CGPoint(x: 1, y: 0), about: .zero) == nil)
    }

    @Test func dragOnAnAnimatedParameterAddsAKeyframe() {
        var transform = ClipTransform()
        transform.position = Animatable(.zero, keyframes: [Keyframe(time: .zero, value: CGPoint(x: 0.5, y: 0.5))])
        transform.drag(.move, from: .zero, to: CGPoint(x: 192, y: 0), renderSize: renderSize, at: s(2))
        #expect(transform.position.keyframes.map(\.time) == [.zero, s(2)])
        #expect(approximately(transform.position.value(at: s(2)), CGPoint(x: 0.6, y: 0.5)))
        // The others weren't animated, and still aren't.
        #expect(!transform.scale.isAnimated)
    }
}

struct MaskHandleTests {
    private let renderSize = CGSize(width: 1920, height: 1080)

    /// A layer of a full-frame picture at half size in the top-left quarter.
    private var quarterLayer: LayerPlacement {
        var clip = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: s(10)))
        clip.transform.position = Animatable(CGPoint(x: 0.25, y: 0.25))
        clip.transform.scale = Animatable(0.5)
        return LayerPlacement(clip: clip, pictureSize: renderSize, renderSize: renderSize, at: .zero)
    }

    private var fullLayer: LayerPlacement {
        LayerPlacement(
            clip: Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: s(10))),
            pictureSize: renderSize, renderSize: renderSize, at: .zero
        )
    }

    @Test func placesTheBoxThroughTheLayerTransform() {
        let mask = Mask(.rectangle, center: CGPoint(x: 0.5, y: 0.5), size: CGSize(width: 0.5, height: 0.5))
        let placement = MaskPlacement(mask, in: quarterLayer, at: .zero)
        #expect(approximately(placement.corners[0], CGPoint(x: 240, y: 135)))
        #expect(approximately(placement.corners[2], CGPoint(x: 720, y: 405)))
        #expect(approximately(placement.point(of: .resize(x: 1, y: 0)), CGPoint(x: 720, y: 270)))
    }

    @Test func turnsTheBoxClockwise() {
        let mask = Mask(.rectangle, center: CGPoint(x: 0.5, y: 0.5), size: CGSize(width: 0.5, height: 0.5), rotation: 90)
        let placement = MaskPlacement(mask, in: fullLayer, at: .zero)
        // The right side's middle turns to the bottom.
        #expect(approximately(placement.point(of: .resize(x: 1, y: 0)), CGPoint(x: 960, y: 540 + 480)))
        #expect(approximately(placement.point(of: .rotate, reach: 0), CGPoint(x: 960 + 270, y: 540)))
    }

    @Test func movesTheBoxInThePicturesTerms() {
        var mask = Mask(.ellipse)
        // Half size, so a drag across the frame moves twice as far across the picture.
        mask.drag(.move, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 196, y: 154), in: quarterLayer, at: .zero)
        #expect(approximately(mask.center.value, CGPoint(x: 0.6, y: 0.6)))
    }

    @Test func resizesAboutTheCentre() {
        var mask = Mask(.rectangle)
        mask.drag(.resize(x: 1, y: 1), from: CGPoint(x: 1440, y: 810), to: CGPoint(x: 1536, y: 864), in: fullLayer, at: .zero)
        #expect(approximately(mask.size.value.width, 0.6))
        #expect(approximately(mask.size.value.height, 0.6))
        mask.drag(.resize(x: 0, y: -1), from: .zero, to: CGPoint(x: 0, y: 540 - 108), in: fullLayer, at: .zero)
        #expect(approximately(mask.size.value.width, 0.6))
        #expect(approximately(mask.size.value.height, 0.2))
    }

    @Test func resizesAlongTheTurnedBox() {
        var mask = Mask(.rectangle, rotation: 90)
        // Turned a quarter, the box's width runs down the frame.
        mask.drag(.resize(x: 1, y: 0), from: .zero, to: CGPoint(x: 960, y: 540 + 270), in: fullLayer, at: .zero)
        #expect(approximately(mask.size.value.width, 540 / 1920))
    }

    @Test func rotatesAboutTheBoxCentre() {
        var mask = Mask(.rectangle, center: CGPoint(x: 0.25, y: 0.5))
        mask.drag(.rotate, from: CGPoint(x: 480, y: 100), to: CGPoint(x: 900, y: 540), in: fullLayer, at: .zero)
        #expect(approximately(mask.rotation.value, 90))
    }

    @Test func feathersByTheDistancePastTheEdge() {
        var mask = Mask(.ellipse)
        mask.drag(.feather, from: .zero, to: CGPoint(x: 1440 + 96, y: 540), in: fullLayer, at: .zero)
        #expect(approximately(mask.feather.value, 0.05))
        let placement = MaskPlacement(mask, in: fullLayer, at: .zero)
        #expect(approximately(placement.point(of: .feather), CGPoint(x: 1536, y: 540)))
        // Pulled inside the edge, it's sharp.
        mask.drag(.feather, from: .zero, to: CGPoint(x: 1000, y: 540), in: fullLayer, at: .zero)
        #expect(mask.feather.value == 0)
    }

    @Test func movesAPathPoint() {
        var mask = Mask(.path)
        let placement = MaskPlacement(mask, in: fullLayer, at: .zero)
        #expect(approximately(placement.point(of: .vertex(0)), CGPoint(x: 960, y: 270)))
        // The top point to the box's top-left corner.
        mask.drag(.vertex(0), from: .zero, to: CGPoint(x: 480, y: 270), in: fullLayer, at: .zero)
        #expect(approximately(mask.path.value.vertices[0].point, .zero))
        #expect(mask.path.value.vertices[1] == MaskPath.diamond.vertices[1])
    }

    @Test func dragOnAnAnimatedPathAddsAKeyframe() {
        var mask = Mask(.path)
        mask.path = Animatable(.diamond, keyframes: [Keyframe(time: .zero, value: .diamond)])
        mask.drag(.vertex(2), from: .zero, to: CGPoint(x: 960, y: 900), in: fullLayer, at: s(1))
        #expect(mask.path.keyframes.map(\.time) == [.zero, s(1)])
        #expect(mask.path.value(at: .zero) == .diamond)
    }
}
