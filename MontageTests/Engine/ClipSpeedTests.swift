import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// Seconds.
private func s(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
    CMTime(value: value, timescale: timescale)
}

struct ClipSpeedTests {
    @Test func keepsLengthsExact() throws {
        let half = try #require(ClipSpeed(media: 1, timeline: 2))
        let frames = CMTime(value: 1001 * 7, timescale: 30000)
        #expect(half.timelineDuration(ofMedia: frames) == CMTime(value: 1001 * 14, timescale: 30000))
        #expect(half.mediaDuration(ofTimeline: half.timelineDuration(ofMedia: frames)) == frames)
        let odd = try #require(ClipSpeed(media: 3, timeline: 7))
        #expect(odd.timelineDuration(ofMedia: odd.mediaDuration(ofTimeline: frames)) == frames)
    }

    @Test func reducesAndRoundsToSimpleFractions() throws {
        let speed = try #require(ClipSpeed(media: s(10), timeline: s(20)))
        #expect(speed == ClipSpeed(media: 1, timeline: 2))
        // As Final Cut writes half speed.
        let written = try #require(ClipSpeed(rate: (10033333333.0 / 1e9) / (60200.0 / 3000)))
        #expect(written == ClipSpeed(media: 1, timeline: 2))
        #expect(ClipSpeed(rate: 0) == nil)
        #expect(ClipSpeed(media: s(0), timeline: s(1)) == nil)
    }

    @Test func combinesSpeeds() throws {
        let half = try #require(ClipSpeed(media: 1, timeline: 2))
        let triple = try #require(ClipSpeed(media: 3, timeline: 1))
        #expect(half.combined(with: triple) == ClipSpeed(media: 3, timeline: 2))
        #expect(half.combined(with: .normal) == half)
    }

    @Test func aClipLastsItsMediaAtItsSpeed() throws {
        var clip = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: s(2), duration: s(4)), timelineStart: s(10))
        clip.speed = try #require(ClipSpeed(media: 2, timeline: 1))
        #expect(clip.duration == s(2))
        #expect(clip.timelineRange == CMTimeRange(start: s(10), duration: s(2)))
        #expect(clip.sourceTime(s(11)) == s(4))
    }

    @Test func trimsAndSplitsAtItsSpeed() throws {
        var fixture = TimelineFixture([(0, 2, 4)])
        let id = fixture.id(0)
        fixture.project.updateClip(id) { $0.speed = ClipSpeed(media: 1, timeline: 2)! }
        #expect(fixture.clips[0].duration == s(8))
        // A second off the front takes half a second of media.
        fixture.project.trimClip(id, edge: .start, to: s(1))
        #expect(fixture.clips[0].sourceRange == CMTimeRange(start: s(5, 2), duration: s(7, 2)))
        #expect(fixture.clips[0].timelineRange == CMTimeRange(start: s(1), duration: s(7)))
        // It can't run past the media: 8s of it left from 2.5s is 15s at half speed.
        fixture.project.trimClip(id, edge: .end, to: s(100))
        #expect(fixture.clips[0].timelineRange.end == s(16))

        let split = fixture.project.splitClip(id, at: s(4))
        let after = try #require(split)
        let second = try #require(fixture.project.clip(id: after)?.clip)
        #expect(second.speed == fixture.clips[0].speed)
        #expect(second.timelineStart == s(4))
        #expect(second.sourceRange.start == s(4))
        #expect(fixture.clips[0].timelineRange.end == s(4))
    }

    @Test func isSavedOnlyWhenItsChanged() throws {
        var clip = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: s(4)))
        #expect(!String(decoding: try JSONEncoder().encode(clip), as: UTF8.self).contains("speed"))
        clip.speed = try #require(ClipSpeed(media: 1, timeline: 4))
        let decoded = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(decoded.speed == clip.speed)
        #expect(decoded.duration == s(16))
    }
}
