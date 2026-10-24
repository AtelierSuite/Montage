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

struct PreviewMappingTests {
    @Test func fitsTheFrameIntoAWiderView() {
        let mapping = PreviewMapping(renderSize: CGSize(width: 1920, height: 1080), viewSize: CGSize(width: 1000, height: 360))
        #expect(mapping.pictureRect == CGRect(x: 180, y: 0, width: 640, height: 360))
        #expect(approximately(mapping.scale, 1 / 3))
    }

    @Test func fitsTheFrameIntoATallerView() {
        let mapping = PreviewMapping(renderSize: CGSize(width: 1920, height: 1080), viewSize: CGSize(width: 960, height: 1000))
        #expect(mapping.pictureRect == CGRect(x: 0, y: 230, width: 960, height: 540))
    }

    @Test func mapsBetweenViewAndRenderPoints() {
        let mapping = PreviewMapping(renderSize: CGSize(width: 1920, height: 1080), viewSize: CGSize(width: 1000, height: 360))
        #expect(approximately(mapping.renderPoint(fromView: CGPoint(x: 180, y: 0)), .zero))
        #expect(approximately(mapping.renderPoint(fromView: CGPoint(x: 500, y: 180)), CGPoint(x: 960, y: 540)))
        let point = CGPoint(x: 123, y: 456)
        #expect(approximately(mapping.renderPoint(fromView: mapping.viewPoint(fromRender: point)), point))
    }
}

struct LayerPlacementTests {
    private let renderSize = CGSize(width: 1920, height: 1080)

    private func clip(position: CGPoint = CGPoint(x: 0.5, y: 0.5), scale: Double = 1, rotation: Double = 0) -> Clip {
        var clip = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: s(10)))
        clip.transform.position = Animatable(position)
        clip.transform.scale = Animatable(scale)
        clip.transform.rotation = Animatable(rotation)
        return clip
    }

    @Test func pillarboxesAnUprightPicture() {
        let placement = LayerPlacement(clip: clip(), pictureSize: CGSize(width: 1080, height: 1920), renderSize: renderSize, at: .zero)
        #expect(approximately(placement.pictureRect.width, 607.5))
        #expect(approximately(placement.pictureRect.midX, 960))
        #expect(placement.contains(CGPoint(x: 960, y: 540)))
        #expect(!placement.contains(CGPoint(x: 100, y: 540)))
    }

    @Test func matchesWhereTheCompositorPutsThePicture() {
        let naturalSize = CGSize(width: 1920, height: 1080)
        // A recording made upright, stored on its side.
        let preferred = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        let fitted = CGRect(origin: .zero, size: naturalSize)
            .applying(FrameComposer.fitTransform(naturalSize: naturalSize, preferredTransform: preferred, renderSize: renderSize))
        let placement = LayerPlacement(clip: clip(), pictureSize: CGSize(width: 1080, height: 1920), renderSize: renderSize, at: .zero)
        #expect(approximately(placement.pictureRect.origin, fitted.origin))
        #expect(approximately(placement.pictureRect.width, fitted.width))
        #expect(approximately(placement.pictureRect.height, fitted.height))
    }

    @Test func followsTheClipTransform() {
        let placement = LayerPlacement(
            clip: clip(position: CGPoint(x: 0.25, y: 0.25), scale: 0.5), pictureSize: renderSize, renderSize: renderSize, at: .zero
        )
        #expect(approximately(placement.center, CGPoint(x: 480, y: 270)))
        #expect(approximately(placement.corners[0], CGPoint(x: 0, y: 0)))
        #expect(approximately(placement.corners[2], CGPoint(x: 960, y: 540)))
        #expect(placement.contains(CGPoint(x: 100, y: 100)))
        #expect(!placement.contains(CGPoint(x: 1000, y: 600)))
    }

    @Test func turnsClockwise() {
        let placement = LayerPlacement(clip: clip(rotation: 90), pictureSize: renderSize, renderSize: renderSize, at: .zero)
        // The top-left corner turns a quarter clockwise, to the top right.
        #expect(approximately(placement.corners[0], CGPoint(x: 960 + 540, y: 540 - 960)))
        // Turned upright, it no longer reaches the frame's sides.
        #expect(!placement.contains(CGPoint(x: 100, y: 540)))
        #expect(placement.contains(CGPoint(x: 960, y: 100)))
    }

    @Test func evaluatesKeyframesAtTheTime() {
        var clip = clip()
        clip.transform.position = Animatable(.zero, keyframes: [
            Keyframe(time: .zero, value: CGPoint(x: 0, y: 0.5)), Keyframe(time: s(2), value: CGPoint(x: 1, y: 0.5)),
        ])
        let placement = LayerPlacement(clip: clip, pictureSize: renderSize, renderSize: renderSize, at: s(1))
        #expect(approximately(placement.center, CGPoint(x: 960, y: 540)))
    }

    @Test func picksTheTopmostLayerUnderAPoint() {
        var fixture = TimelineFixture([(0, 0, 5)])
        var overlay = Clip(mediaID: fixture.video.id, sourceRange: CMTimeRange(start: .zero, duration: s(5)))
        overlay.transform.position = Animatable(CGPoint(x: 0.75, y: 0.75))
        overlay.transform.scale = Animatable(0.25)
        fixture.project.tracks.append(Track(kind: .video, clips: [overlay]))
        fixture.project.settings.renderSize = renderSize
        let project = fixture.project
        let bottom = fixture.id(0)

        #expect(project.layer(at: CGPoint(x: 1440, y: 810), time: s(1))?.clipID == overlay.id)
        #expect(project.layer(at: CGPoint(x: 200, y: 200), time: s(1))?.clipID == bottom)
        // Left out of the composition, it's not there to pick.
        #expect(project.layer(at: CGPoint(x: 1440, y: 810), time: s(1), excluding: [overlay.id])?.clipID == bottom)
        // Nothing's showing after the clips end.
        #expect(project.layer(at: CGPoint(x: 200, y: 200), time: s(6)) == nil)
        // Outside the frame.
        #expect(project.layer(at: CGPoint(x: -10, y: 200), time: s(1)) == nil)
    }

    @Test func picksAStillImageLayerByItsFittedPicture() {
        var fixture = TimelineFixture()
        fixture.project.settings.renderSize = renderSize
        let still = Clip(mediaID: fixture.image.id, sourceRange: CMTimeRange(start: .zero, duration: s(5)))
        fixture.project.tracks[0].insert(still)
        let project = fixture.project
        // A square picture, pillarboxed in the middle of the frame.
        #expect(project.layer(at: CGPoint(x: 960, y: 540), time: s(1))?.clipID == still.id)
        #expect(project.layer(at: CGPoint(x: 300, y: 540), time: s(1)) == nil)
        #expect(project.layerPlacements(at: s(1)).first?.pictureRect == CGRect(x: 420, y: 0, width: 1080, height: 1080))
    }

    @Test func skipsHiddenTracksAndFadedClips() {
        var fixture = TimelineFixture([(0, 0, 5)])
        fixture.project.settings.renderSize = renderSize
        var project = fixture.project
        project.updateClip(fixture.id(0)) { $0.opacity = Animatable(0) }
        #expect(project.layer(at: CGPoint(x: 960, y: 540), time: s(1)) == nil)
        project = fixture.project
        project.tracks[0].isHidden = true
        #expect(project.layer(at: CGPoint(x: 960, y: 540), time: s(1)) == nil)
    }
}
