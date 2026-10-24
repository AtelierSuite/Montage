import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct AnimatableTests {
    @Test func constantValueHoldsThroughout() {
        let value = Animatable(0.5)
        #expect(value.value(at: .zero) == 0.5)
        #expect(value.value(at: CMTime(value: 100, timescale: 1)) == 0.5)
    }

    @Test func interpolatesBetweenKeyframes() {
        var value = Animatable(0.0)
        value.setKeyframe(Keyframe(time: CMTime(value: 2, timescale: 1), value: 10))
        value.setKeyframe(Keyframe(time: .zero, value: 0))
        #expect(value.keyframes.map(\.value) == [0, 10])
        #expect(value.value(at: CMTime(value: 1, timescale: 1)) == 5)
        // Outside the keyframes, the nearest one holds.
        #expect(value.value(at: CMTime(value: -1, timescale: 1)) == 0)
        #expect(value.value(at: CMTime(value: 3, timescale: 1)) == 10)
    }

    @Test func holdJumpsAtTheNextKeyframe() {
        let value = Animatable(0.0, keyframes: [
            Keyframe(time: .zero, value: 0, interpolation: .hold),
            Keyframe(time: CMTime(value: 2, timescale: 1), value: 10),
        ])
        #expect(value.value(at: CMTime(value: 1999, timescale: 1000)) == 0)
        #expect(value.value(at: CMTime(value: 2, timescale: 1)) == 10)
    }

    @Test func settingAKeyframeAtTheSameTimeReplacesIt() {
        var value = Animatable(0.0)
        value.setKeyframe(Keyframe(time: .zero, value: 1))
        value.setKeyframe(Keyframe(time: .zero, value: 2))
        #expect(value.keyframes.count == 1)
        #expect(value.keyframes.first?.value == 2)
    }
}

struct ProjectCodingTests {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(value))
    }

    private func sampleProject() -> Project {
        let media = MediaItem(
            name: "Clip.mov", kind: .video, location: .package(path: "Media/Clip.mov"),
            metadata: MediaMetadata(
                duration: CMTime(value: 600_600, timescale: 30000), naturalSize: CGSize(width: 1920, height: 1080),
                rotation: 90, nominalFrameRate: 29.97, isVariableFrameRate: true,
                audioChannelCount: 2, audioSampleRate: 48000
            )
        )
        var clip = Clip(
            mediaID: media.id,
            sourceRange: CMTimeRange(start: CMTime(value: 1001, timescale: 30000), duration: CMTime(value: 5, timescale: 1)),
            timelineStart: CMTime(value: 3, timescale: 2)
        )
        clip.opacity.setKeyframe(Keyframe(time: .zero, value: 0, interpolation: .easeIn))
        clip.opacity.setKeyframe(Keyframe(time: CMTime(value: 1, timescale: 1), value: 1))
        clip.effects = [Effect(.colorCorrection(ColorCorrection())), Effect(isEnabled: false, .reverb(Reverb()))]
        return Project(
            settings: ProjectSettings(frameDuration: CMTime(value: 1001, timescale: 30000)),
            media: [media],
            tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio, isMuted: true)]
        )
    }

    @Test func projectRoundTrips() throws {
        let project = sampleProject()
        #expect(try roundTrip(project) == project)
    }

    @Test func timesAreWrittenAsExactRationals() throws {
        let json = String(decoding: try JSONEncoder().encode(sampleProject()), as: UTF8.self)
        #expect(json.contains(#""1001\/30000""#))
    }

    @Test func aProjectFromBeforeTracksStillOpens() throws {
        let project = try JSONDecoder().decode(Project.self, from: Data(#"{"formatVersion": 1}"#.utf8))
        #expect(project.tracks.isEmpty)
        #expect(project.media.isEmpty)
        #expect(project.settings == ProjectSettings())
    }

    @Test func effectsNameTheirKind() throws {
        let json = String(decoding: try JSONEncoder().encode(Effect(.mosaic(Mosaic()))), as: UTF8.self)
        #expect(json.contains(#""type":"mosaic""#))
    }
}

struct TrackTests {
    private func clip(at seconds: Int64, length: Int64 = 2) -> Clip {
        Clip(
            mediaID: UUID(),
            sourceRange: CMTimeRange(start: .zero, duration: CMTime(value: length, timescale: 1)),
            timelineStart: CMTime(value: seconds, timescale: 1)
        )
    }

    @Test func keepsClipsInTimelineOrder() {
        var track = Track(kind: .video, clips: [clip(at: 4), clip(at: 0)])
        #expect(track.clips.map(\.timelineStart.seconds) == [0, 4])
        let moved = track.clips[0].id
        track.update(moved) { $0.timelineStart = CMTime(value: 8, timescale: 1) }
        #expect(track.clips.last?.id == moved)
    }

    @Test func appendsAtTheEnd() {
        var track = Track(kind: .video, clips: [clip(at: 1, length: 3)])
        track.append(clip(at: 0))
        #expect(track.clips.last?.timelineStart == CMTime(value: 4, timescale: 1))
        #expect(track.end == CMTime(value: 6, timescale: 1))
    }

    @Test func mapsTimelineTimeToSourceTime() {
        let clip = Clip(
            mediaID: UUID(),
            sourceRange: CMTimeRange(start: CMTime(value: 10, timescale: 1), duration: CMTime(value: 5, timescale: 1)),
            timelineStart: CMTime(value: 2, timescale: 1)
        )
        #expect(clip.sourceTime(CMTime(value: 3, timescale: 1)) == CMTime(value: 11, timescale: 1))
        #expect(clip.localTime(CMTime(value: 3, timescale: 1)) == CMTime(value: 1, timescale: 1))
    }
}
