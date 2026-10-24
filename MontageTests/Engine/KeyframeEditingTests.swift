import CoreGraphics
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct KeyframeEditingTests {
    private func s(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// A ten-second clip with opacity keyframed at 1 s and 3 s, and a mosaic
    /// whose mask is keyframed at 3 s and 6 s.
    private func clip() -> Clip {
        var clip = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: s(10)))
        clip.opacity = Animatable(1, keyframes: [
            Keyframe(time: s(1), value: 0), Keyframe(time: s(3), value: 1, interpolation: .easeIn),
        ])
        var mask = Mask(.ellipse)
        mask.center = Animatable(CGPoint(x: 0.5, y: 0.5), keyframes: [
            Keyframe(time: s(3), value: CGPoint(x: 0.2, y: 0.2), interpolation: .easeIn),
            Keyframe(time: s(6), value: CGPoint(x: 0.8, y: 0.8)),
        ])
        clip.effects = [Effect(.mosaic(Mosaic()), mask: mask)]
        return clip
    }

    @Test func listsEveryParameterKeyframeTimeOnce() {
        #expect(clip().keyframeTimes == [s(1), s(3), s(6)])
    }

    @Test func findsPreviousAndNextKeyframe() {
        let clip = clip()
        #expect(clip.keyframeTime(before: s(3)) == s(1))
        #expect(clip.keyframeTime(after: s(3)) == s(6))
        #expect(clip.keyframeTime(before: s(1)) == nil)
        #expect(clip.keyframeTime(after: s(6)) == nil)
        #expect(clip.keyframeTime(after: s(0)) == s(1))
    }

    @Test func retimesKeyframesOfEveryParameterAtATime() {
        var clip = clip()
        clip.moveKeyframes(from: s(3), to: s(4))
        #expect(clip.keyframeTimes == [s(1), s(4), s(6)])
        #expect(clip.opacity.keyframes.map(\.time) == [s(1), s(4)])
        #expect(clip.opacity.keyframes[1].interpolation == .easeIn)
        #expect(clip.effects[0].mask?.center.keyframes.first?.time == s(4))
    }

    @Test func retimingKeepsKeyframesWithinTheClip() {
        var clip = clip()
        clip.moveKeyframes(from: s(6), to: s(20))
        #expect(clip.keyframeTimes.last == s(10))
        clip.moveKeyframes(from: s(1), to: s(-2))
        #expect(clip.keyframeTimes.first == .zero)
    }

    @Test func retimingOntoAnotherKeyframeReplacesIt() {
        var clip = clip()
        clip.moveKeyframes(from: s(1), to: s(3))
        #expect(clip.opacity.keyframes.count == 1)
        #expect(clip.opacity.keyframes[0].value == 0)
    }

    @Test func retimingChangesWhenValuesAreReached() {
        var clip = clip()
        clip.moveKeyframes(from: s(3), to: s(5))
        // Linear from 0 at 1 s to 1 at 5 s.
        #expect(abs(clip.opacity.value(at: s(3)) - 0.5) < 1e-9)
    }

    @Test func readsTheSharedInterpolation() {
        let clip = clip()
        #expect(clip.keyframeInterpolation(at: s(3)) == .easeIn)
        #expect(clip.keyframeInterpolation(at: s(1)) == .linear)
        #expect(clip.keyframeInterpolation(at: s(2)) == nil)
    }

    @Test func mixedInterpolationsReadAsNone() {
        var clip = clip()
        clip.opacity.setInterpolation(.hold, at: s(3))
        #expect(clip.keyframeInterpolation(at: s(3)) == nil)
    }

    @Test func changesEasingOfEveryKeyframeAtATime() {
        var clip = clip()
        let curve = TimingCurve(x1: 0.1, y1: 0.7, x2: 0.3, y2: 1)
        clip.setKeyframeInterpolation(.bezier(curve), at: s(3))
        #expect(clip.opacity.interpolation(at: s(3)) == .bezier(curve))
        #expect(clip.effects[0].mask?.center.interpolation(at: s(3)) == .bezier(curve))
        #expect(clip.opacity.interpolation(at: s(1)) == .linear)
        clip.setKeyframeInterpolation(.hold, at: s(3))
        #expect(clip.effects[0].mask?.center.value(at: s(5)) == CGPoint(x: 0.2, y: 0.2))
    }

    @Test func settingInterpolationWhereThereIsNoKeyframeDoesNothing() {
        var parameter = Animatable(1.0, keyframes: [Keyframe(time: s(1), value: 2)])
        parameter.setInterpolation(.hold, at: s(2))
        #expect(parameter.keyframes == [Keyframe(time: s(1), value: 2)])
    }

    @Test func removesKeyframesAtATimeHoldingTheValue() {
        var clip = clip()
        clip.removeKeyframes(at: s(6))
        clip.removeKeyframes(at: s(3))
        #expect(clip.keyframeTimes == [s(1)])
        #expect(clip.effects[0].mask?.center.isAnimated == false)
        #expect(clip.effects[0].mask?.center.value == CGPoint(x: 0.2, y: 0.2))
    }

    @Test func visitsAudioEffectParameters() {
        var clip = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: s(10)))
        var equalizer = Equalizer()
        equalizer.bands[2].gain = Animatable(0, keyframes: [Keyframe(time: s(2), value: 6)])
        clip.effects = [Effect(.equalizer(equalizer))]
        #expect(clip.keyframeTimes == [s(2)])
        clip.moveKeyframes(from: s(2), to: s(7))
        guard case .equalizer(let moved) = clip.effects[0].kind else {
            Issue.record("The effect changed kind")
            return
        }
        #expect(moved.bands[2].gain.keyframes.map(\.time) == [s(7)])
    }

    @Test func updatesAClipOnWhicheverTrackHoldsIt() {
        let fixture = TimelineFixture([(0, 0, 4)])
        var project = fixture.project
        project.updateClip(fixture.id(0)) { $0.blendMode = .screen }
        #expect(project.tracks[0].clips[0].blendMode == .screen)
    }
}
