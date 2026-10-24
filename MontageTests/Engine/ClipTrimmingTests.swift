import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// Seconds, as the times the tests build their timelines from.
private func s(_ seconds: Int64) -> CMTime {
    CMTime(value: seconds, timescale: 1)
}

private func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
    CMTimeRange(start: s(start), duration: s(duration))
}

struct TrimTests {
    @Test func trimsTheEndBackLeavingAGap() {
        var fixture = TimelineFixture([(0, 0, 5), (5, 5, 5)])
        let end = fixture.project.trimClip(fixture.id(0), edge: .end, to: s(3))
        #expect(end == s(3))
        #expect(fixture.clips[0].timelineRange == range(0, 3))
        #expect(fixture.clips[1].timelineStart == s(5))
    }

    @Test func trimmingTheEndStopsAtTheNextClipAndTheMediasEnd() {
        var fixture = TimelineFixture([(0, 0, 4), (5, 0, 5)])
        #expect(fixture.project.trimClip(fixture.id(0), edge: .end, to: s(8)) == s(5))
        var alone = TimelineFixture([(0, 6, 2)])
        // Four seconds of media are left after the source start of 6.
        #expect(alone.project.trimClip(alone.id(0), edge: .end, to: s(9)) == s(4))
        #expect(alone.clips[0].sourceRange == range(6, 4))
    }

    @Test func trimsTheStartTakingTheSameMediaUnderEachFrame() {
        var fixture = TimelineFixture([(2, 2, 6)])
        fixture.project.trimClip(fixture.id(0), edge: .start, to: s(4))
        #expect(fixture.clips[0].timelineRange == range(4, 4))
        #expect(fixture.clips[0].sourceRange == range(4, 4))
    }

    @Test func trimmingTheStartStopsAtTheMediasStartAndThePreviousClip() {
        var fixture = TimelineFixture([(5, 1, 3)])
        // The media starts a second before the clip does.
        #expect(fixture.project.trimClip(fixture.id(0), edge: .start, to: s(0)) == s(4))
        var blocked = TimelineFixture([(0, 0, 3), (5, 5, 3)])
        #expect(blocked.project.trimClip(blocked.id(1), edge: .start, to: s(1)) == s(3))
        #expect(blocked.clips[1].sourceRange == range(3, 5))
    }

    @Test func neverTrimsShorterThanAFrame() {
        var fixture = TimelineFixture([(0, 0, 5)])
        let end = fixture.project.trimClip(fixture.id(0), edge: .end, to: s(-2))
        #expect(end == fixture.project.settings.frameDuration)
        #expect(fixture.clips[0].duration == fixture.project.settings.frameDuration)
    }

    @Test func trimmingTheStartMovesKeyframesWithTheMedia() {
        var fixture = TimelineFixture([(0, 0, 10)])
        fixture.project.tracks[0].update(fixture.id(0)) {
            $0.opacity.setKeyframe(Keyframe(time: s(5), value: 0.5))
        }
        fixture.project.trimClip(fixture.id(0), edge: .start, to: s(2))
        #expect(fixture.clips[0].opacity.keyframes.map(\.time) == [s(3)])
    }

    @Test func aStillGrowsEitherWayWithoutMovingItsSource() {
        var fixture = TimelineFixture()
        let still = Clip(mediaID: fixture.image.id, sourceRange: range(0, 5), timelineStart: s(10))
        fixture.project.tracks[0].insert(still)
        fixture.project.trimClip(still.id, edge: .start, to: s(2))
        fixture.project.trimClip(still.id, edge: .end, to: s(100))
        #expect(fixture.clips[0].timelineRange == range(2, 98))
        #expect(fixture.clips[0].sourceRange.start == .zero)
    }

    @Test func rippleTrimmingTheEndMovesTheClipsAfter() {
        var fixture = TimelineFixture([(0, 0, 4), (4, 0, 2), (8, 0, 2)])
        fixture.project.trimClip(fixture.id(0), edge: .end, to: s(6), style: .ripple)
        #expect(fixture.clips.map(\.timelineStart) == [s(0), s(6), s(10)])
        fixture.project.trimClip(fixture.id(0), edge: .end, to: s(1), style: .ripple)
        #expect(fixture.clips.map(\.timelineStart) == [s(0), s(1), s(5)])
    }

    @Test func rippleTrimmingTheStartKeepsTheClipInPlace() {
        var fixture = TimelineFixture([(2, 0, 6), (8, 0, 2)])
        fixture.project.trimClip(fixture.id(0), edge: .start, to: s(4), style: .ripple)
        #expect(fixture.clips[0].timelineRange == range(2, 4))
        #expect(fixture.clips[0].sourceRange == range(2, 4))
        #expect(fixture.clips[1].timelineStart == s(6))
        // Back out again, as far as the media goes.
        fixture.project.trimClip(fixture.id(0), edge: .start, to: s(-5), style: .ripple)
        #expect(fixture.clips[0].sourceRange == range(0, 6))
        #expect(fixture.clips[1].timelineStart == s(8))
    }

    @Test func rollingMovesTheCutBetweenTwoClips() {
        var fixture = TimelineFixture([(0, 0, 5), (5, 3, 5)])
        let cut = fixture.project.trimClip(fixture.id(0), edge: .end, to: s(4), style: .roll)
        #expect(cut == s(4))
        #expect(fixture.clips[0].timelineRange == range(0, 4))
        #expect(fixture.clips[1].timelineRange == range(4, 6))
        #expect(fixture.clips[1].sourceRange == range(2, 6))
    }

    @Test func rollingStopsWhereEitherClipRunsOutOfMedia() {
        var fixture = TimelineFixture([(0, 0, 5), (5, 3, 5)])
        // The second clip's media starts three seconds before it does.
        #expect(fixture.project.trimClip(fixture.id(1), edge: .start, to: s(0), style: .roll) == s(2))
        // The first clip's media ends ten seconds after it starts.
        #expect(fixture.project.trimClip(fixture.id(1), edge: .start, to: s(20), style: .roll) == s(10) - fixture.project.settings.frameDuration)
        #expect(fixture.clips[0].timelineRange.end == fixture.clips[1].timelineStart)
    }

    @Test func rollingWithoutATouchingNeighbourTrims() {
        var fixture = TimelineFixture([(0, 0, 4), (5, 0, 5)])
        #expect(fixture.project.trimClip(fixture.id(0), edge: .end, to: s(7), style: .roll) == s(5))
        #expect(fixture.clips[1].timelineStart == s(5))
    }
}

struct SplitTests {
    @Test func splitsIntoTwoClipsThatPlayTheSame() throws {
        var fixture = TimelineFixture([(2, 1, 6)])
        let split = fixture.project.splitClip(fixture.id(0), at: s(5))
        let id = try #require(split)
        #expect(fixture.clips.count == 2)
        #expect(fixture.clips[0].timelineRange == range(2, 3))
        #expect(fixture.clips[0].sourceRange == range(1, 3))
        #expect(fixture.clips[1].id == id)
        #expect(fixture.clips[1].timelineRange == range(5, 3))
        #expect(fixture.clips[1].sourceRange == range(4, 3))
    }

    @Test func theSecondHalfKeepsItsKeyframesWhereTheyWere() {
        var fixture = TimelineFixture([(0, 0, 10)])
        fixture.project.tracks[0].update(fixture.id(0)) {
            $0.volume.setKeyframe(Keyframe(time: s(2), value: 0))
            $0.volume.setKeyframe(Keyframe(time: s(8), value: 1))
        }
        fixture.project.splitClip(fixture.id(0), at: s(4))
        let after = fixture.clips[1]
        #expect(after.volume.keyframes.map(\.time) == [s(-2), s(4)])
        // Halfway between the keyframes, as it was before the split.
        #expect(after.volume.value(at: after.localTime(s(5))) == 0.5)
    }

    @Test func doesntSplitAtAnEdge() {
        var fixture = TimelineFixture([(0, 0, 5)])
        #expect(fixture.project.splitClip(fixture.id(0), at: .zero) == nil)
        #expect(fixture.project.splitClip(fixture.id(0), at: s(5)) == nil)
        #expect(fixture.project.splitClip(fixture.id(0), at: s(7)) == nil)
        #expect(fixture.clips.count == 1)
    }

    @Test func splitsEveryClipUnderTheTimeUnlessGivenSome() {
        var fixture = TimelineFixture([(0, 0, 5)])
        let audio = Clip(mediaID: fixture.video.id, sourceRange: range(0, 5))
        fixture.project.tracks.append(Track(kind: .audio, clips: [audio]))
        #expect(fixture.project.splitClips([audio.id], at: s(2)).count == 1)
        #expect(fixture.project.tracks.map(\.clips.count) == [1, 2])
        #expect(fixture.project.splitClips(at: s(3)).count == 2)
        #expect(fixture.project.tracks.map(\.clips.count) == [2, 3])
    }
}
