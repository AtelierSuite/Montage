import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct EDLExportTests {
    private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
        CMTime(value: value, timescale: timescale)
    }

    private func video(_ name: String, sound: Bool = true) -> MediaItem {
        MediaItem(name: name, kind: .video, location: .package(path: "Media/\(name)"), metadata: MediaMetadata(
            duration: seconds(20), naturalSize: CGSize(width: 1920, height: 1080), nominalFrameRate: 30,
            audioChannelCount: sound ? 2 : 0, audioSampleRate: 48000
        ))
    }

    /// A project with more than an EDL holds: two video tracks, three
    /// audio tracks, text, and markers.
    private func sampleProject(frameDuration: CMTime = CMTime(value: 1, timescale: 30), videoSound: Bool = true) -> Project {
        let opening = video("IMG_1805.MOV"), second = video("IMG_1813.MOV"), sound = video("IMG_1841.MOV")
        let tree = MediaItem(name: "Tree.png", kind: .image, location: .package(path: "Media/Tree.png"),
                             metadata: MediaMetadata(naturalSize: CGSize(width: 1024, height: 768)))
        var first = Clip(mediaID: opening.id, sourceRange: CMTimeRange(start: seconds(1), duration: seconds(3)))
        first.isAudioDetached = !videoSound
        var later = Clip(mediaID: second.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)), timelineStart: seconds(5))
        later.isAudioDetached = true
        let still = Clip(mediaID: tree.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)), timelineStart: seconds(3))
        let title = Clip(content: .text(TextContent("Hello")), sourceRange: CMTimeRange(start: .zero, duration: seconds(1)),
                         timelineStart: seconds(8))
        let overlay = Clip(mediaID: tree.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(1)), timelineStart: seconds(1))
        let music = Clip(mediaID: sound.id, sourceRange: CMTimeRange(start: seconds(2), duration: seconds(4)),
                         timelineStart: seconds(1, 2))
        let echo = Clip(mediaID: opening.id, sourceRange: CMTimeRange(start: seconds(8), duration: seconds(1)), timelineStart: seconds(6))
        let extra = Clip(mediaID: sound.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(1)), timelineStart: seconds(2))
        return Project(
            settings: ProjectSettings(renderSize: CGSize(width: 1920, height: 1080), frameDuration: frameDuration),
            media: [opening, second, sound, tree],
            tracks: [
                Track(kind: .video, clips: [first, still, later, title]), Track(kind: .video, clips: [overlay]),
                Track(kind: .audio, clips: [music]), Track(kind: .audio, clips: [echo]), Track(kind: .audio, clips: [extra]),
            ],
            markers: [Marker(time: seconds(1), name: "Start\nhere"), Marker(time: seconds(6))]
        )
    }

    private func export(_ project: Project) -> String {
        String(decoding: ProjectInterchange.edl(for: project, named: "Round Trip", mediaResolver: .none), as: UTF8.self)
    }

    @Test func writesCMX3600Lines() {
        let text = export(sampleProject())
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines.prefix(2) == ["TITLE: Round Trip", "FCM: NON-DROP FRAME"])
        #expect(lines.contains("001  AX       B     C        00:00:01:00 00:00:04:00 01:00:00:00 01:00:03:00"))
        #expect(lines.contains("002  AX       A2    C        00:00:02:00 00:00:06:00 01:00:00:15 01:00:04:15"))
        #expect(lines.contains("003  AX       V     C        00:00:00:00 00:00:02:00 01:00:03:00 01:00:05:00"))
        #expect(lines.contains("* FROM CLIP NAME: IMG_1805.MOV"))
        #expect(lines.contains("* SOURCE FILE: IMG_1805.MOV"))
        #expect(lines.contains("* LOC: 01:00:01:00 RED     Start here"))
        #expect(lines.contains("* LOC: 01:00:06:00 RED"))
        // Only the first audio track fits beside the picture's sound.
        #expect(!text.contains("00:00:08:00 00:00:09:00"))
    }

    @Test func listsWhatsLeftOut() {
        let project = sampleProject()
        let leftOut = Set(ProjectInterchange.clipsLeftOutOfEDL(in: project))
        let expected = [project.tracks[0].clips[3], project.tracks[1].clips[0], project.tracks[3].clips[0], project.tracks[4].clips[0]]
        #expect(leftOut == Set(expected.map(\.id)))
        // With no sound on the picture, two audio tracks fit.
        let silent = sampleProject(videoSound: false)
        #expect(ProjectInterchange.clipsLeftOutOfEDL(in: silent).count == 3)
    }

    @Test func roundTripsTheVideoTrackAndAudio() throws {
        let project = sampleProject()
        let imported = try ProjectInterchange.read(Data(export(project).utf8), baseURL: URL(fileURLWithPath: "/tmp"))
        #expect(imported.name == "Round Trip")
        #expect(imported.project.settings.frameDuration == seconds(1, 30))
        let tracks = imported.project.tracks
        #expect(tracks.map(\.kind) == [.video, .audio])

        let video = tracks[0].clips
        #expect(video.map { imported.project.mediaItem(id: $0.mediaID)?.name } == ["IMG_1805.MOV", "Tree.png", "IMG_1813.MOV"])
        #expect(video.map(\.timelineRange) == project.tracks[0].clips.prefix(3).map(\.timelineRange))
        #expect(video[0].sourceRange == project.tracks[0].clips[0].sourceRange)
        #expect(!video[0].isAudioDetached)
        #expect(video[2].isAudioDetached)
        #expect(video[1].content == .image(imported.project.mediaItem(id: video[1].mediaID)!.id))

        let music = try #require(tracks[1].clips.first)
        #expect(tracks[1].clips.count == 1)
        #expect(music.timelineRange == project.tracks[2].clips[0].timelineRange)
        #expect(music.sourceRange == project.tracks[2].clips[0].sourceRange)

        #expect(imported.project.markers.map(\.time) == [seconds(1), seconds(6)])
        #expect(imported.project.markers.map(\.name) == ["Start here", ""])
        #expect(imported.issues(.changed) == [.frameRateAssumed("30")])
    }

    @Test func roundTripsDropFrameWithTwoAudioTracks() throws {
        let frame = CMTime(value: 1001, timescale: 30000)
        let project = sampleProject(frameDuration: frame, videoSound: false)
        let text = export(project)
        #expect(text.contains("FCM: DROP FRAME"))
        #expect(text.contains("01:00:00;00"))
        let imported = try ProjectInterchange.read(Data(text.utf8))
        #expect(imported.project.settings.frameDuration == frame)
        #expect(imported.project.tracks.map(\.kind) == [.video, .audio, .audio])
        let conformed = { (time: CMTime) in InterchangeTime.conformed(time, to: frame) }
        let video = imported.project.tracks[0].clips
        #expect(video.map(\.timelineStart) == project.tracks[0].clips.prefix(3).map { conformed($0.timelineStart) })
        #expect(video[0].isAudioDetached)
        let echo = try #require(imported.project.tracks[2].clips.first)
        #expect(echo.timelineStart == conformed(seconds(6)))
        #expect(echo.sourceRange.start == conformed(seconds(8)))
        #expect(imported.project.markers.map(\.time) == [conformed(seconds(1)), conformed(seconds(6))])
    }

    @Test func writesTheMediaPathsTheResolverFinds() {
        let project = sampleProject()
        let resolver = MediaResolver { URL(fileURLWithPath: "/Volumes/Footage/\($0.name)") }
        let text = String(decoding: ProjectInterchange.edl(for: project, named: "Paths", mediaResolver: resolver), as: UTF8.self)
        #expect(text.contains("* SOURCE FILE: /Volumes/Footage/IMG_1805.MOV"))
    }
}
