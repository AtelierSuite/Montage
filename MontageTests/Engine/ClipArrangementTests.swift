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

struct DeleteTests {
    @Test func deletingLeavesAGap() {
        var fixture = TimelineFixture([(0, 0, 2), (2, 0, 2), (4, 0, 2)])
        fixture.project.removeClips([fixture.id(1)])
        #expect(fixture.clips.map(\.timelineStart) == [s(0), s(4)])
    }

    @Test func rippleDeletingClosesTheGapsOnTheirTracks() {
        var fixture = TimelineFixture([(0, 0, 2), (2, 0, 2), (5, 0, 2), (7, 0, 2)])
        let other = Clip(mediaID: fixture.video.id, sourceRange: range(0, 2), timelineStart: s(6))
        fixture.project.tracks.append(Track(kind: .audio, clips: [other]))
        fixture.project.rippleDeleteClips([fixture.id(0), fixture.id(2)])
        // The gap between the second and third clips stays.
        #expect(fixture.clips.map(\.timelineStart) == [s(0), s(3)])
        #expect(fixture.project.tracks[1].clips[0].timelineStart == s(6))
    }
}

struct MoveTests {
    @Test func movesAlongATrack() {
        var fixture = TimelineFixture([(0, 0, 2), (4, 0, 2)])
        fixture.project.moveClips([fixture.id(0)], by: s(7))
        #expect(fixture.clips.map(\.timelineStart) == [s(4), s(7)])
    }

    @Test func neverMovesBeforeTheStart() {
        var fixture = TimelineFixture([(2, 0, 2), (6, 0, 2)])
        fixture.project.moveClips([fixture.id(0), fixture.id(1)], by: s(-5))
        // Held back so the first starts at the start, the second as far behind.
        #expect(fixture.clips.map(\.timelineStart) == [s(0), s(4)])
    }

    @Test func coversWhatItLandsOn() {
        var fixture = TimelineFixture([(0, 0, 2), (4, 0, 6)])
        let moved = fixture.id(0)
        fixture.project.moveClips([moved], by: s(6))
        // Lands in the middle of the second clip, cutting it in two around it.
        #expect(fixture.clips.map(\.timelineRange) == [range(4, 2), range(6, 2), range(8, 2)])
        #expect(fixture.clips[1].id == moved)
        #expect(fixture.clips[2].sourceRange == range(4, 2))
    }

    @Test func movesOntoAnotherTrackOfTheSameKind() {
        var fixture = TimelineFixture([(0, 0, 2)])
        fixture.project.tracks.append(Track(kind: .video))
        fixture.project.tracks.append(Track(kind: .audio))
        let id = fixture.id(0)
        fixture.project.moveClips([id], by: .zero, trackOffsets: [.video: 1])
        #expect(fixture.project.tracks[0].clips.isEmpty)
        #expect(fixture.project.tracks[1].clips.map(\.id) == [id])
        // Audio tracks are no place for it.
        fixture.project.moveClips([id], by: .zero, trackOffsets: [.audio: 1])
        #expect(fixture.project.tracks[1].clips.map(\.id) == [id])
    }

    @Test func makesOneTrackForClipsMovedPastTheLast() {
        var fixture = TimelineFixture([(0, 0, 2), (3, 0, 2)])
        fixture.project.tracks.append(Track(kind: .audio))
        fixture.project.moveClips([fixture.id(0), fixture.id(1)], by: .zero, trackOffsets: [.video: 5])
        #expect(fixture.project.tracks.map(\.kind) == [.video, .video, .audio])
        #expect(fixture.project.tracks[1].clips.count == 2)
        // Moving past the first stays on the first.
        fixture.project.moveClips(Set(fixture.project.tracks[1].clips.map(\.id)), by: .zero, trackOffsets: [.video: -5])
        #expect(fixture.project.tracks[0].clips.count == 2)
    }
}

struct DetachAudioTests {
    @Test func splitsTheSoundOffOntoAnAudioTrack() throws {
        var fixture = TimelineFixture([(3, 1, 4)])
        fixture.project.tracks[0].update(fixture.id(0)) {
            $0.volume = Animatable(0.5)
            $0.effects = [Effect(.gain(Gain())), Effect(.mosaic(Mosaic()))]
        }
        let detached = fixture.project.detachAudio(from: fixture.id(0))
        let id = try #require(detached)
        #expect(fixture.project.tracks.map(\.kind) == [.video, .audio])
        let video = fixture.clips[0]
        let audio = try #require(fixture.project.tracks[1].clip(id: id))
        #expect(video.isAudioDetached)
        #expect(audio.mediaID == video.mediaID)
        #expect(audio.sourceRange == video.sourceRange)
        #expect(audio.timelineStart == video.timelineStart)
        #expect(audio.volume.value == 0.5)
        #expect(audio.effects.map(\.kind.isVideo) == [false])
        #expect(video.effects.map(\.kind.isVideo) == [true])
        // Once is all.
        #expect(!fixture.project.canDetachAudio(from: video.id))
        #expect(fixture.project.detachAudio(from: video.id) == nil)
    }

    @Test func usesTheFirstAudioTrackWithRoom() {
        var fixture = TimelineFixture([(0, 0, 4)])
        let busy = Clip(mediaID: fixture.video.id, sourceRange: range(0, 2), timelineStart: s(3))
        fixture.project.tracks += [Track(kind: .audio, clips: [busy]), Track(kind: .audio)]
        fixture.project.detachAudio(from: fixture.id(0))
        #expect(fixture.project.tracks.map(\.clips.count) == [1, 1, 1])
    }

    @Test func onlyVideoWithSoundCanBeDetached() {
        var fixture = TimelineFixture()
        let still = Clip(mediaID: fixture.image.id, sourceRange: range(0, 5))
        fixture.project.tracks[0].insert(still)
        #expect(!fixture.project.canDetachAudio(from: still.id))
        let silent = MediaItem(name: "silent", kind: .video, location: .package(path: "Media/silent"),
                               metadata: MediaMetadata(duration: s(5), naturalSize: CGSize(width: 10, height: 10)))
        fixture.project.media.append(silent)
        let clip = Clip(mediaID: silent.id, sourceRange: range(0, 5), timelineStart: s(5))
        fixture.project.tracks[0].insert(clip)
        #expect(fixture.project.detachAudio(from: clip.id) == nil)
    }
}
