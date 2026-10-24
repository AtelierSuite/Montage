import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct ProjectEditingTests {
    private func item(_ kind: MediaItem.Kind, seconds: Int64 = 10) -> MediaItem {
        MediaItem(name: "\(kind)", kind: kind, location: .package(path: "Media/\(kind)"),
                  metadata: MediaMetadata(duration: kind == .image ? .zero : CMTime(value: seconds, timescale: 1)))
    }

    @Test func addsVideoToANewVideoTrackBeforeTheAudioTracks() throws {
        let video = item(.video)
        var project = Project(media: [video], tracks: [Track(kind: .audio)])
        let appended = project.appendClip(of: video.id)
        let id = try #require(appended)
        #expect(project.tracks.map(\.kind) == [.video, .audio])
        #expect(project.tracks[0].clips.map(\.id) == [id])
        #expect(project.tracks[0].clips[0].sourceRange == CMTimeRange(start: .zero, duration: CMTime(value: 10, timescale: 1)))
    }

    @Test func appendsAfterWhatsOnTheTrack() {
        let video = item(.video, seconds: 3)
        let image = item(.image)
        var project = Project(media: [video, image])
        project.appendClip(of: video.id)
        project.appendClip(of: image.id)
        #expect(project.tracks.count == 1)
        let clips = project.tracks[0].clips
        #expect(clips.map(\.timelineStart) == [.zero, CMTime(value: 3, timescale: 1)])
        #expect(clips[1].duration == Project.defaultImageDuration)
    }

    @Test func addsAudioToTheFirstAudioTrack() {
        let audio = item(.audio)
        var project = Project(media: [audio], tracks: [Track(kind: .video), Track(kind: .audio), Track(kind: .audio)])
        project.appendClip(of: audio.id)
        #expect(project.tracks[1].clips.count == 1)
        #expect(project.tracks[2].clips.isEmpty)
    }

    @Test func doesNothingForMediaNotInTheProject() {
        var project = Project()
        #expect(project.appendClip(of: UUID()) == nil)
        #expect(project.tracks.isEmpty)
    }

    @Test func removingMediaRemovesItsClips() {
        let kept = item(.video)
        let removed = item(.audio)
        var project = Project(media: [kept, removed])
        project.appendClip(of: kept.id)
        project.appendClip(of: removed.id)
        project.appendClip(of: removed.id)
        project.removeMedia([removed.id])
        #expect(project.media == [kept])
        #expect(project.tracks.flatMap(\.clips).map(\.mediaID) == [kept.id])
    }
}
