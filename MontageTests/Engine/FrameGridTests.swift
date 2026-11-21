import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// A time as AVFoundation often gives it, in nanoseconds.
private func ns(_ value: Int64) -> CMTime {
    CMTime(value: value, timescale: 1_000_000_000)
}

private func frame(_ number: Int64, of frameDuration: CMTime = CMTime(value: 1, timescale: 30)) -> CMTime {
    CMTime(value: frameDuration.value * number, timescale: frameDuration.timescale)
}

/// A 30 fps project with one video whose length isn't whole frames, as an
/// iPhone video's often isn't.
private struct OffGridFixture {
    let video = MediaItem(
        name: "video", kind: .video, location: .package(path: "Media/video"),
        metadata: MediaMetadata(duration: ns(37_428_248_397), naturalSize: CGSize(width: 1920, height: 1080), audioChannelCount: 2)
    )
    var project: Project

    init(frameDuration: CMTime = CMTime(value: 1, timescale: 30)) {
        project = Project(settings: ProjectSettings(frameDuration: frameDuration), media: [video], tracks: [Track(kind: .video)])
    }

    var clips: [Clip] { project.tracks[0].clips }
    var frames: FrameTime { project.frames }

    func isOnGrid(_ clip: Clip) -> Bool {
        frames.isOnFrame(clip.timelineStart) && frames.isOnFrame(clip.timelineRange.end)
    }
}

struct FrameTimeRoundingTests {
    private let frames = FrameTime(frameDuration: CMTime(value: 1, timescale: 30))

    @Test func roundsToFramesEitherWay() {
        #expect(frames.nearest(ns(5_166_751_603)) == frame(155))
        #expect(frames.floor(ns(5_183_000_000)) == frame(155))
        #expect(frames.nearest(ns(5_190_000_000)) == frame(156))
        #expect(frames.ceiling(ns(5_166_751_603)) == frame(156))
        #expect(frames.ceiling(frame(155)) == frame(155))
        #expect(frames.nearest(ns(-40_000_000)) == frame(-1))
        #expect(frames.floor(ns(-10_000_000)) == frame(-1))
        #expect(frames.ceiling(ns(-10_000_000)) == .zero)
    }

    @Test func roundsToFramesAt2997() {
        let ntsc = FrameTime(frameDuration: CMTime(value: 1001, timescale: 30000))
        let time = ntsc.nearest(ns(47_595_000_000))
        #expect(ntsc.isOnFrame(time))
        #expect(abs(time.seconds - 47.595) < ntsc.frameDuration.seconds / 2)
        #expect(!ntsc.isOnFrame(CMTime(value: 1, timescale: 30)))
    }
}

struct FrameGridEditingTests {
    @Test func newClipsDropThePartFrameAtTheMediasEnd() {
        var fixture = OffGridFixture()
        fixture.project.appendClip(of: fixture.video.id)
        fixture.project.appendClip(of: fixture.video.id)
        // 37.428 s is 1122.8 frames at 30 fps.
        #expect(fixture.clips.map(\.duration) == [frame(1122), frame(1122)])
        #expect(fixture.clips[1].timelineStart == frame(1122))

        var dropped = OffGridFixture()
        dropped.project.insertClips(of: [dropped.video.id, dropped.video.id], at: ns(47_595_000_000))
        #expect(dropped.clips.allSatisfy(dropped.isOnGrid))
        #expect(dropped.clips[0].timelineStart == frame(1428))
    }

    @Test func stillsAndTitlesLastWholeFrames() {
        let image = MediaItem(
            name: "image", kind: .image, location: .package(path: "Media/image"),
            metadata: MediaMetadata(naturalSize: CGSize(width: 100, height: 100))
        )
        let ntsc = CMTime(value: 1001, timescale: 30000)
        var project = Project(settings: ProjectSettings(frameDuration: ntsc), media: [image], tracks: [Track(kind: .video)])
        project.appendClip(of: image.id)
        let title = project.insertClip(of: .text(TextContent("Title")), at: ns(1_234_567_890))
        let clips = project.tracks.flatMap(\.clips)
        #expect(clips.count == 2)
        #expect(clips.allSatisfy { project.frames.isOnFrame($0.timelineStart) && project.frames.isOnFrame($0.duration) })
        #expect(project.clip(id: title)?.clip.timelineStart == frame(37, of: ntsc))
    }

    @Test func trimmingToAnOffGridTimeLandsOnAFrame() {
        var fixture = OffGridFixture()
        let id = fixture.project.insertClips(of: [fixture.video.id], at: frame(150))[0]
        let start = fixture.project.trimClip(id, edge: .start, to: ns(5_166_751_603))
        #expect(start == frame(155))
        #expect(fixture.clips[0].sourceRange.start == frame(5))
        #expect(fixture.isOnGrid(fixture.clips[0]))

        // Out to the media's end, which falls between frames.
        let end = fixture.project.trimClip(id, edge: .end, to: frame(10_000))
        #expect(end == frame(1272))
        #expect(fixture.frames.isOnFrame(fixture.clips[0].sourceRange.duration))
        #expect(fixture.clips[0].sourceRange.end <= fixture.video.metadata.duration)
    }

    @Test func rollingAndRipplingStayOnFrames() {
        var fixture = OffGridFixture()
        let id = fixture.project.insertClips(of: [fixture.video.id], at: .zero)[0]
        fixture.project.splitClip(id, at: frame(600))
        fixture.project.trimClip(id, edge: .end, to: ns(20_412_345_678), style: .roll)
        #expect(fixture.clips[0].timelineRange.end == frame(612))
        #expect(fixture.clips[1].timelineStart == frame(612))
        #expect(fixture.clips.allSatisfy(fixture.isOnGrid))

        fixture.project.trimClip(id, edge: .start, to: ns(1_049_000_000), style: .ripple)
        #expect(fixture.clips[0].sourceRange.start == frame(31))
        #expect(fixture.clips[1].timelineStart == frame(581))
        #expect(fixture.clips.allSatisfy(fixture.isOnGrid))
    }

    @Test func splittingAtAnOffGridPlayheadCutsOnAFrame() {
        var fixture = OffGridFixture()
        let id = fixture.project.insertClips(of: [fixture.video.id], at: .zero)[0]
        let after = fixture.project.splitClip(id, at: ns(10_020_000_000))
        #expect(after != nil)
        #expect(fixture.clips.map(\.timelineStart) == [.zero, frame(301)])
        #expect(fixture.clips[1].sourceRange.start == frame(301))
        #expect(fixture.clips.allSatisfy(fixture.isOnGrid))
    }

    @Test func movingByAnOffGridOffsetLandsOnAFrame() {
        var fixture = OffGridFixture()
        let ids = fixture.project.insertClips(of: [fixture.video.id], at: .zero)
        fixture.project.moveClips(Set(ids), by: ns(5_166_751_603))
        #expect(fixture.clips[0].timelineStart == frame(155))
        #expect(fixture.isOnGrid(fixture.clips[0]))
    }

    @Test func snapPointsAreOnFrames() {
        var fixture = OffGridFixture()
        fixture.project.addMarker(at: ns(2_990_000_000))
        // The playhead stopped where the player did, part way into frame 155.
        let snapper = TimelineSnapper(project: fixture.project, playhead: ns(5_183_000_000))
        #expect(snapper.points.map(\.time) == [.zero, frame(90), frame(155)])
    }

    /// Media at 29.97 in a 30 fps project is cut in the timeline's frames:
    /// its source range moves by whole timeline frames, not its own.
    @Test func otherRateMediaIsCutInTimelineFrames() {
        var fixture = OffGridFixture()
        fixture.project.media[0].metadata.duration = frame(1000, of: CMTime(value: 1001, timescale: 30000))
        let id = fixture.project.insertClips(of: [fixture.video.id], at: .zero)[0]
        fixture.project.trimClip(id, edge: .start, to: ns(1_000_000_000))
        #expect(fixture.clips[0].sourceRange.start == frame(30))
        #expect(fixture.isOnGrid(fixture.clips[0]))
    }
}
