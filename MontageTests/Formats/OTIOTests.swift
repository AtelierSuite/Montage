import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing
import UniformTypeIdentifiers

private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
    CMTime(value: value, timescale: timescale)
}

private func rational(_ value: Double, _ rate: Double) -> [String: Any] {
    ["OTIO_SCHEMA": "RationalTime.1", "value": value, "rate": rate]
}

struct OTIOTimeTests {
    @Test func readsRationalTimesExactly() {
        #expect(OTIOTime.time(rational(48, 24)) == seconds(2))
        // NTSC rates, written exactly and rounded.
        #expect(OTIOTime.time(rational(30, 30000.0 / 1001)) == seconds(1001, 1000))
        #expect(OTIOTime.time(rational(24, 23.976)) == seconds(1001, 1000))
        #expect(OTIOTime.time(rational(96000, 48000)) == seconds(2))
        // A count that isn't whole, to the microsecond.
        #expect(OTIOTime.time(rational(1.5, 24)) == seconds(62500, 1_000_000))
        #expect(OTIOTime.time(rational(1, 0)) == nil)
        #expect(OTIOTime.time(["value": 1]) == nil)
    }

    @Test func writesFramesAtTheProjectsRate() throws {
        let ntsc = seconds(1001, 30000)
        guard case .object(let fields) = OTIOTime.json(seconds(1001, 1000), frameDuration: ntsc) else {
            Issue.record("Not an object")
            return
        }
        #expect(fields.first { $0.0 == "value" }?.1 == .double(30))
        // Off the frames, it's written in its own timescale, exactly.
        let data = OTIOTime.json(seconds(1, 100), frameDuration: seconds(1, 24)).data()
        let object = try JSONSerialization.jsonObject(with: data)
        #expect(OTIOTime.time(object) == seconds(1, 100))
    }

    @Test func writesWholeNumbersWithAPoint() {
        let text = String(decoding: OTIOJSON.schema("RationalTime.1", [("rate", .double(24)), ("value", .double(0.5))]).data(),
                          as: UTF8.self)
        #expect(text.contains("\"rate\": 24.0"))
        #expect(text.contains("\"value\": 0.5"))
        #expect(text.hasPrefix("{\n    \"OTIO_SCHEMA\": \"RationalTime.1\""))
    }
}

struct OTIOImportTests {
    let imported: ImportedProject

    init() throws {
        imported = try InterchangeFixtures.read("Resolve.otio")
    }

    @Test func declaresItsType() {
        #expect(UTType.otio.conforms(to: .json))
        #expect(ProjectInterchange.importableTypes.contains(.otio))
        #expect(imported.report.format == .otio)
    }

    @Test func readsTheTimeline() {
        #expect(imported.name == "OTIO Sample")
        #expect(imported.project.settings.frameDuration == seconds(1, 24))
        #expect(imported.project.tracks.map(\.kind) == [.video, .video, .audio, .audio])
        #expect(imported.project.duration == seconds(7))
    }

    @Test func placesClipsInSequenceWithGaps() throws {
        let video = imported.project.tracks[0].clips
        #expect(video.map(\.timelineStart) == [seconds(0), seconds(3), seconds(6)])
        #expect(video.map(\.duration) == [seconds(3), seconds(2), seconds(1)])
        // Its media's timecode starts at an hour, its available range's start.
        #expect(video[0].sourceRange.start == seconds(1))
        #expect(imported.project.mediaItem(id: video[2].mediaID)?.name == "Lost.mov")
    }

    @Test func makesPictureAndSoundInStepOneClip() throws {
        let opening = try #require(imported.clip("IMG_1805.MOV"))
        #expect(opening.track == 0)
        #expect(!opening.clip.isAudioDetached)
        #expect(imported.clips(of: "IMG_1805.MOV").count == 1)
        // A picture without its sound plays without it.
        #expect(try #require(imported.clip("IMG_1813.MOV")).clip.isAudioDetached)
    }

    @Test func readsMediaReferences() throws {
        let opening = try #require(imported.clip("IMG_1805.MOV")?.clip)
        let item = try #require(imported.project.mediaItem(id: opening.mediaID))
        #expect(item.kind == .video)
        #expect(item.metadata.duration == seconds(20))
        #expect(imported.mediaSources[item.id] == URL(fileURLWithPath: "/Volumes/Footage/IMG_1805.MOV"))
        let second = try #require(imported.clip("IMG_1813.MOV")?.clip.mediaID)
        #expect(imported.mediaSources[second] == InterchangeFixtures.directory.appending(path: "IMG_1813.MOV"))
        let lost = try #require(imported.project.tracks[0].clips.last?.mediaID)
        #expect(imported.mediaSources[lost] == nil)
    }

    @Test func flattensANestedStackTrimmedToItsRange() throws {
        let tree = try #require(imported.clip("How-to-draw-a-cartoon-tree-20.png"))
        #expect(tree.track == 1)
        #expect(tree.clip.content == .image(tree.clip.mediaID!))
        #expect(tree.clip.timelineRange == CMTimeRange(start: seconds(1), duration: seconds(2)))
    }

    @Test func readsAudioAtItsOwnRate() throws {
        let music = try #require(imported.project.tracks[2].clips.last)
        #expect(music.sourceRange == CMTimeRange(start: seconds(2), duration: seconds(4)))
        #expect(music.timelineStart == seconds(3))
    }

    @Test func mutesATrackTurnedOff() {
        #expect(imported.project.tracks[3].isMuted)
        #expect(!imported.project.tracks[2].isMuted)
        #expect(!imported.project.tracks[0].isHidden)
    }

    @Test func bringsMarkersOntoTheTimeline() {
        #expect(imported.project.markers.map(\.time) == [seconds(1), seconds(2)])
        #expect(imported.project.markers.map(\.name) == ["Beat", "Chapter"])
    }

    @Test func reportsWhatDidntComeAcross() throws {
        #expect(imported.issues(.changed) == [.transition(name: "Cross Dissolve")])
        #expect(imported.report.items(in: .changed).first?.time == seconds(3))
        #expect(imported.issues(.unsupportedEffect) == [.unsupportedEffect(name: "Glow")])
        #expect(imported.issues(.notImported) == [.generator(name: "SolidColor")])
        // The effect stays on its clip, turned off.
        let opening = try #require(imported.clip("IMG_1805.MOV")?.clip)
        guard case .unsupported(let glow) = opening.effects.first?.kind else {
            Issue.record("No unsupported effect")
            return
        }
        #expect(opening.effects.first?.isEnabled == false)
        #expect(glow.format == "otio")
        #expect(glow.parameters == [.init(name: "radius", key: "radius", value: "12")])
    }

    @Test func readsEveryTimelineOfACollectionsFirst() throws {
        let timeline = try JSONSerialization.jsonObject(with: Data(contentsOf: InterchangeFixtures.directory.appending(path: "Resolve.otio")))
        let collection: [String: Any] = ["OTIO_SCHEMA": "SerializableCollection.1", "name": "Bin", "children": [timeline, timeline]]
        let read = try ProjectInterchange.read(JSONSerialization.data(withJSONObject: collection))
        #expect(read.name == "OTIO Sample")
        #expect(read.issues(.notImported).contains(.otherTimelines(count: 1)))
    }

    @Test func namesAnUnnamedTimelineAfterItsFile() throws {
        let folder = URL.temporaryDirectory.appending(path: "OTIO-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Rough Cut.otio")
        try ProjectInterchange.otio(for: Project(), named: "", mediaResolver: .none).write(to: file)
        #expect(try ProjectInterchange.read(contentsOf: file).name == "Rough Cut")
        // A timeline's own name stays.
        try Data(contentsOf: InterchangeFixtures.directory.appending(path: "Resolve.otio")).write(to: file)
        #expect(try ProjectInterchange.read(contentsOf: file).name == "OTIO Sample")
    }

    /// A clip timed by its media's timecode, with no available range to say
    /// where the media's time starts, as some writers leave it: 01:00:00:10
    /// is a third of a second into a movie whose timecode starts at
    /// 01:00:00:00. Once there's no timecode, the times are as they are.
    @Test(arguments: [true, false])
    func timesAClipByItsMediasTimecode(hasTimecode: Bool) async throws {
        let folder = URL.temporaryDirectory.appending(path: "OTIO-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let movie = folder.appending(path: "A001.mov")
        let hour: Int32 = 60 * 60 * 30
        try await TestMovie.write(to: movie, width: 64, height: 36, timecode: hasTimecode ? hour : nil)
        let start = Double(hasTimecode ? hour + 10 : 10)
        let clip: [String: Any] = [
            "OTIO_SCHEMA": "Clip.2", "name": "A001",
            "source_range": ["OTIO_SCHEMA": "TimeRange.1", "start_time": rational(start, 30), "duration": rational(15, 30)],
            "media_references": ["DEFAULT_MEDIA": ["OTIO_SCHEMA": "ExternalReference.1", "target_url": movie.absoluteString]],
            "active_media_reference_key": "DEFAULT_MEDIA",
        ]
        let timeline: [String: Any] = [
            "OTIO_SCHEMA": "Timeline.1", "name": "Cut",
            "tracks": ["OTIO_SCHEMA": "Stack.1", "children": [["OTIO_SCHEMA": "Track.1", "kind": "Video", "children": [clip]]]],
        ]
        let read = try ProjectInterchange.read(JSONSerialization.data(withJSONObject: timeline))
        let imported = await ProjectInterchange.gatherMedia(for: read, into: PackageMediaStore())
        #expect(imported.issues(.missingMedia).isEmpty)
        let placed = try #require(imported.project.tracks.first?.clips.first)
        #expect(placed.sourceRange == CMTimeRange(start: seconds(10, 30), duration: seconds(15, 30)))
    }

    @Test func refusesWhatIsntOTIO() {
        #expect(throws: InterchangeError.unsupportedFormat) { try ProjectInterchange.read(Data(#"{"name": "x"}"#.utf8)) }
        #expect(throws: InterchangeError.self) { try ProjectInterchange.read(Data(#"{"OTIO_SCHEMA": "#.utf8)) }
        #expect(throws: InterchangeError.noTimeline) {
            try ProjectInterchange.read(Data(#"{"OTIO_SCHEMA": "SerializableCollection.1", "children": []}"#.utf8))
        }
    }
}

struct OTIOExportTests {
    private func video(_ name: String) -> MediaItem {
        MediaItem(name: name, kind: .video, location: .package(path: "Media/\(name)"), metadata: MediaMetadata(
            duration: seconds(20), naturalSize: CGSize(width: 1920, height: 1080), nominalFrameRate: 30,
            audioChannelCount: 2, audioSampleRate: 48000
        ))
    }

    /// Something of everything the export writes.
    private func sampleProject() -> Project {
        let opening = video("IMG_1805.MOV"), second = video("IMG_1813.MOV"), sound = video("IMG_1841.MOV")
        let tree = MediaItem(name: "Tree.png", kind: .image, location: .package(path: "Media/Tree.png"),
                             metadata: MediaMetadata(naturalSize: CGSize(width: 1024, height: 768)))

        var first = Clip(mediaID: opening.id, sourceRange: CMTimeRange(start: seconds(1), duration: seconds(3)))
        first.volume = Animatable(0.5, keyframes: [Keyframe(time: .zero, value: 0), Keyframe(time: seconds(1), value: 0.5)])
        first.transform.scale = Animatable(0.8)
        var blur = Mosaic()
        blur.style = .blur
        first.effects = [Effect(.mosaic(blur))]
        var later = Clip(mediaID: second.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)), timelineStart: seconds(5))
        later.isAudioDetached = true
        let detached = Clip(mediaID: second.id, sourceRange: later.sourceRange, timelineStart: later.timelineStart)

        let still = Clip(mediaID: tree.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)), timelineStart: seconds(1))
        let title = Clip(content: .text(TextContent("Hello\nWorld")), sourceRange: CMTimeRange(start: .zero, duration: seconds(1)), timelineStart: seconds(4))
        let music = Clip(mediaID: sound.id, sourceRange: CMTimeRange(start: seconds(2), duration: seconds(4)), timelineStart: seconds(1, 2))

        return Project(
            settings: ProjectSettings(renderSize: CGSize(width: 1280, height: 720), frameDuration: seconds(1001, 30000)),
            media: [opening, second, sound, tree],
            tracks: [
                Track(kind: .video, clips: [first, later]), Track(kind: .video, clips: [still, title], isHidden: true),
                Track(kind: .audio, clips: [music, detached]),
            ],
            markers: [Marker(time: seconds(2), name: "Chorus"), Marker(time: seconds(6))]
        )
    }

    private let resolver = MediaResolver { URL(fileURLWithPath: "/Volumes/Media").appending(path: $0.name) }

    private func export(_ project: Project) -> Data {
        ProjectInterchange.otio(for: project, named: "Round Trip", mediaResolver: resolver)
    }

    @Test func roundTripsThroughOTIO() throws {
        let project = sampleProject()
        let imported = try ProjectInterchange.read(export(project))
        #expect(imported.name == "Round Trip")
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        #expect(imported.project.settings == project.settings)
        #expect(imported.project.markers.map(\.time) == project.markers.map(\.time))
        #expect(imported.project.markers.map(\.name) == project.markers.map(\.name))
        #expect(imported.project.tracks.map(\.kind) == project.tracks.map(\.kind))
        #expect(imported.project.tracks.map(\.isHidden) == project.tracks.map(\.isHidden))
        #expect(Set(imported.project.media.map(\.name)) == Set(project.media.map(\.name)))

        for (track, back) in zip(project.tracks, imported.project.tracks) {
            #expect(back.clips.count == track.clips.count)
            for (clip, copy) in zip(track.clips, back.clips) {
                #expect(imported.project.mediaItem(id: copy.mediaID)?.name == project.mediaItem(id: clip.mediaID)?.name)
                #expect(copy.sourceRange == clip.sourceRange)
                #expect(copy.timelineStart == clip.timelineStart)
                #expect(copy.isAudioDetached == clip.isAudioDetached)
                #expect(copy.volume == clip.volume)
                #expect(copy.transform == clip.transform)
                #expect(copy.effects == clip.effects)
                if clip.mediaID == nil { #expect(copy.content == clip.content) }
            }
        }
    }

    @Test func writesOTIOsSchema() throws {
        let root = try #require(try JSONSerialization.jsonObject(with: export(sampleProject())) as? [String: Any])
        #expect(root["OTIO_SCHEMA"] as? String == "Timeline.1")
        let stack = try #require(root["tracks"] as? [String: Any])
        #expect(stack["OTIO_SCHEMA"] as? String == "Stack.1")
        let tracks = try #require(stack["children"] as? [[String: Any]])
        // Montage's tracks, then the sound of the first video track's clip.
        #expect(tracks.map { $0["kind"] as? String } == ["Video", "Video", "Audio", "Audio"])
        #expect(tracks.map { $0["enabled"] as? Bool } == [true, false, true, true])

        let first = try #require(tracks[0]["children"] as? [[String: Any]])
        #expect(first.map { $0["OTIO_SCHEMA"] as? String } == ["Clip.2", "Gap.1", "Clip.2"])
        #expect(OTIOTime.range(first[1]["source_range"]) == CMTimeRange(start: .zero, duration: seconds(2)))
        #expect(OTIOTime.range(first[0]["source_range"]) == CMTimeRange(start: seconds(1), duration: seconds(3)))
        let start = try #require(root["global_start_time"] as? [String: Any])
        #expect(start["value"] as? Double == 0)
        #expect(abs((start["rate"] as? Double ?? 0) - 30000.0 / 1001) < 0.000001)
        let reference = try #require((first[0]["media_references"] as? [String: Any])?["DEFAULT_MEDIA"] as? [String: Any])
        #expect(reference["OTIO_SCHEMA"] as? String == "ExternalReference.1")
        #expect(reference["target_url"] as? String == "file:///Volumes/Media/IMG_1805.MOV")
        #expect(OTIOTime.range(reference["available_range"]) == CMTimeRange(start: .zero, duration: seconds(20)))

        let titles = try #require(tracks[1]["children"] as? [[String: Any]])
        let generator = try #require((titles.last?["media_references"] as? [String: Any])?["DEFAULT_MEDIA"] as? [String: Any])
        #expect(generator["generator_kind"] as? String == "Text")
        #expect(titles.last?["name"] as? String == "Hello")
        let markers = try #require(stack["markers"] as? [[String: Any]])
        #expect(markers.map { $0["OTIO_SCHEMA"] as? String } == ["Marker.2", "Marker.2"])
    }

    /// A project with a clip at half speed.
    private func retimedProject() -> Project {
        let media = video("IMG_1805.MOV")
        var slow = Clip(mediaID: media.id, sourceRange: CMTimeRange(start: seconds(4), duration: seconds(1)), timelineStart: seconds(1))
        slow.speed = ClipSpeed(media: 1, timeline: 2)!
        return Project(
            settings: ProjectSettings(renderSize: CGSize(width: 1920, height: 1080), frameDuration: seconds(1, 30)),
            media: [media], tracks: [Track(kind: .video, clips: [slow])]
        )
    }

    @Test func roundTripsAClipAtAnotherSpeed() throws {
        let imported = try ProjectInterchange.read(export(retimedProject()))
        let slow = try #require(imported.clip("IMG_1805.MOV")?.clip)
        #expect(slow.speed == ClipSpeed(media: 1, timeline: 2))
        #expect(slow.sourceRange == CMTimeRange(start: seconds(4), duration: seconds(1)))
        #expect(slow.timelineRange == CMTimeRange(start: seconds(1), duration: seconds(2)))
    }

    /// Read by another app that keeps none of Montage's metadata, the
    /// clips still come back where they were, playing what they did.
    @Test func roundTripsWithoutMontagesMetadata() throws {
        let project = sampleProject()
        var root = try #require(try JSONSerialization.jsonObject(with: export(project)) as? [String: Any])
        root = Self.removingMontageMetadata(root) as! [String: Any]
        let imported = try ProjectInterchange.read(JSONSerialization.data(withJSONObject: root))
        #expect(imported.project.tracks.map(\.kind) == [.video, .video, .audio])
        let opening = try #require(imported.clip("IMG_1805.MOV"))
        #expect(!opening.clip.isAudioDetached)
        #expect(imported.clips(of: "IMG_1805.MOV").count == 1)
        #expect(opening.clip.sourceRange == CMTimeRange(start: seconds(1), duration: seconds(3)))
        // Text that no other app could draw is reported as a generator.
        #expect(imported.issues(.notImported) == [.generator(name: "Text")])
        // The detached picture and its sound make one clip again.
        #expect(imported.clips(of: "IMG_1813.MOV").count == 1)
        #expect(imported.project.settings.frameDuration == seconds(1001, 30000))
    }

    @Test func writesAnotherSpeedAsALinearTimeWarp() throws {
        var root = try #require(try JSONSerialization.jsonObject(with: export(retimedProject())) as? [String: Any])
        let json = String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self)
        #expect(json.contains("LinearTimeWarp.1"))
        root = Self.removingMontageMetadata(root) as! [String: Any]
        let imported = try ProjectInterchange.read(JSONSerialization.data(withJSONObject: root))
        #expect(!imported.report.items.contains { $0.issue == .speedChange })
        let slow = try #require(imported.clip("IMG_1805.MOV")?.clip)
        #expect(slow.speed == ClipSpeed(media: 1, timeline: 2))
        #expect(slow.sourceRange == CMTimeRange(start: seconds(4), duration: seconds(1)))
        #expect(slow.timelineRange == CMTimeRange(start: seconds(1), duration: seconds(2)))
    }

    private static func removingMontageMetadata(_ value: Any) -> Any {
        if var object = value as? [String: Any] {
            if var metadata = object["metadata"] as? [String: Any] {
                metadata[OTIOJSON.montageKey] = nil
                object["metadata"] = metadata
            }
            return object.mapValues(removingMontageMetadata)
        }
        if let array = value as? [Any] { return array.map(removingMontageMetadata) }
        return value
    }
}
