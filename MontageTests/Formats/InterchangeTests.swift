import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Hand-made interchange files, kept beside the tests.
enum InterchangeFixtures {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appending(path: "Fixtures", directoryHint: .isDirectory)

    static func read(_ name: String, baseURL: URL? = nil) throws -> ImportedProject {
        let data = try Data(contentsOf: directory.appending(path: name))
        return try ProjectInterchange.read(data, baseURL: baseURL ?? directory)
    }
}

extension ImportedProject {
    /// The clips named in the file, wherever they went.
    func clip(_ name: String, on kind: Track.Kind? = nil) -> (track: Int, clip: Clip)? {
        for (index, track) in project.tracks.enumerated() where kind == nil || track.kind == kind {
            for clip in track.clips where project.mediaItem(id: clip.mediaID)?.name == name {
                return (index, clip)
            }
        }
        return nil
    }

    func clips(of name: String) -> [Clip] {
        project.tracks.flatMap(\.clips).filter { project.mediaItem(id: $0.mediaID)?.name == name }
    }

    func issues(_ category: ImportReport.Category) -> [ImportReport.Issue] {
        report.items(in: category).map(\.issue)
    }
}

private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
    CMTime(value: value, timescale: timescale)
}

struct InterchangeTimeTests {
    @Test func readsRationalTimesExactly() {
        #expect(InterchangeTime.parse("1001/30000s") == CMTime(value: 1001, timescale: 30000))
        #expect(InterchangeTime.parse("5s") == seconds(5))
        #expect(InterchangeTime.parse("0s") == .zero)
        #expect(InterchangeTime.parse("7209/2s") == seconds(7209, 2))
        #expect(InterchangeTime.parse("1.5s") == seconds(3, 2))
        #expect(InterchangeTime.parse("nonsense") == nil)
        // A numerator past 32 bits, as an hour of 23.976 at its timescale.
        #expect(InterchangeTime.parse("86313600000/24000s") == seconds(3596400, 1))
    }

    @Test func writesTimesReduced() {
        #expect(InterchangeTime.string(CMTime(value: 2002, timescale: 60000)) == "1001/30000s")
        #expect(InterchangeTime.string(CMTime(value: 600, timescale: 600)) == "1s")
        #expect(InterchangeTime.string(.zero) == "0s")
    }

    @Test func conformsToFrames() {
        let frame = CMTime(value: 1001, timescale: 30000)
        #expect(InterchangeTime.conformed(CMTime(value: 1, timescale: 1), to: frame) == CMTime(value: 30030, timescale: 30000))
        #expect(InterchangeTime.frameDuration(timebase: 30, ntsc: true) == frame)
        #expect(InterchangeTime.frameDuration(timebase: 25, ntsc: false) == seconds(1, 25))
    }
}

struct MarkupElementTests {
    @Test func readsAndWritesElements() throws {
        let element = try MarkupElement.parse(Data(#"<a x="1 &amp; 2"><b>text</b><c/></a>"#.utf8))
        #expect(element["x"] == "1 & 2")
        #expect(element.child("b")?.text == "text")
        #expect(element.children.map(\.name) == ["b", "c"])
        #expect(try MarkupElement.parse(Data(element.xmlString().utf8)) == element)
    }

    @Test func refusesWhatIsntXML() {
        #expect(throws: InterchangeError.self) { try MarkupElement.parse(Data("<a><b></a>".utf8)) }
        #expect(throws: InterchangeError.unsupportedFormat) { try ProjectInterchange.read(Data("<html/>".utf8)) }
    }
}

struct FCPXMLImportTests {
    private let imported: ImportedProject

    init() throws {
        imported = try InterchangeFixtures.read("Storylines.fcpxml")
    }

    @Test func takesTheSequenceSettings() {
        #expect(imported.name == "Storylines")
        #expect(imported.project.settings.renderSize == CGSize(width: 1920, height: 1080))
        #expect(imported.project.settings.frameDuration == seconds(1, 30))
    }

    @Test func makesOneMediaItemForEachFile() {
        let names = imported.project.media.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.contains("IMG_3312.mp4"))
        let tree = imported.project.media.first { $0.name == "How-to-draw-a-cartoon-tree-20.png" }
        #expect(tree?.kind == .image)
        let source = imported.project.media.first { $0.name == "IMG_1805.MOV" }
        #expect(source?.metadata.duration == seconds(20))
        #expect(source?.metadata.naturalSize == CGSize(width: 1920, height: 1080))
        #expect(source?.metadata.audioChannelCount == 2)
        // Placeholders in the package, with the files the project named.
        #expect(source?.location == .package(path: "Media/IMG_1805.MOV"))
        #expect(imported.mediaSources[source!.id] == InterchangeFixtures.directory.appending(path: "IMG_1805.MOV"))
    }

    @Test func laysThePrimaryStorylineFromTheSequenceTimecode() throws {
        let opening = try #require(imported.clip("IMG_1805.MOV", on: .video))
        #expect(opening.clip.timelineStart == .zero)
        #expect(opening.clip.sourceRange.start == seconds(1))
        // Cut halfway through the dissolve.
        #expect(opening.clip.duration == seconds(5))
        let primary = imported.project.tracks[opening.track]
        let names = primary.clips.map { imported.project.mediaItem(id: $0.mediaID)!.name }
        #expect(names == [
            "IMG_1805.MOV", "IMG_3311.MOV", "IMG_3312.MOV", "IMG_3313.MOV", "IMG_3314.MOV", "IMG_3312.mp4",
            "IMG_1813.MOV", "How-to-draw-a-cartoon-tree-20.png", "IMG_3312.MOV",
        ])
    }

    @Test func flattensACompoundClipWithinItsRange() throws {
        let primary = try #require(imported.clip("IMG_1805.MOV", on: .video)).track
        let clips = imported.project.tracks[primary].clips
        // The compound's first clip starts under the dissolve, from the cut.
        #expect(clips[1].timelineStart == seconds(5))
        #expect(clips[1].sourceRange.start == seconds(1, 2))
        // Its second is trimmed to the end of the compound.
        #expect(clips[2].timelineRange == CMTimeRange(start: seconds(13, 2), duration: seconds(1)))
    }

    @Test func connectsClipsOnLanesAsTracks() throws {
        let primary = try #require(imported.clip("IMG_1805.MOV", on: .video)).track
        let above = imported.project.tracks[primary + 1].clips
        // With the title connected to the gap later on the same lane.
        #expect(above.map(\.timelineStart) == [seconds(1), seconds(15, 2)])
        #expect(above.map { imported.project.mediaItem(id: $0.mediaID)?.name } == ["IMG_1813.MOV", nil])
        #expect(above.last?.content.text?.string == "Hello")
        // The secondary storyline on lane 2 goes above it.
        let storyline = imported.project.tracks[primary + 2].clips
        #expect(storyline.map(\.timelineStart) == [seconds(2), seconds(3)])
        #expect(imported.project.tracks[primary + 2].kind == .video)
    }

    @Test func putsConnectedSoundOnAudioTracks() throws {
        let below = try #require(imported.clip("IMG_1841.MOV", on: .audio))
        #expect(below.clip.timelineRange == CMTimeRange(start: .zero, duration: seconds(4)))
        let synced = imported.clips(of: "IMG_3311.MOV").filter { imported.project.tracks[imported.track(of: $0)].kind == .audio }
        #expect(synced.map(\.timelineStart) == [seconds(21, 2)])
        // Audio tracks come after every video track.
        let kinds = imported.project.tracks.map(\.kind)
        #expect(kinds == kinds.sorted { $0 == .video && $1 == .audio })
    }

    @Test func playsAMulticamClipsChosenAngles() throws {
        let camera = try #require(imported.clip("IMG_3313.MOV", on: .video)).clip
        #expect(camera.timelineRange == CMTimeRange(start: seconds(17, 2), duration: seconds(2)))
        #expect(camera.isAudioDetached)
        let recorder = imported.clips(of: "IMG_1805.MOV").first { imported.project.tracks[imported.track(of: $0)].kind == .audio }
        #expect(recorder?.timelineStart == seconds(17, 2))
    }

    @Test func keepsAPlainClipsPictureAndSoundTogether() throws {
        let plain = try #require(imported.clip("IMG_3312.mp4")).clip
        #expect(!plain.isAudioDetached)
        #expect(imported.project.tracks[try #require(imported.clip("IMG_3312.mp4")).track].kind == .video)
        #expect(imported.clips(of: "IMG_3312.mp4").count == 1)
    }

    @Test func readsSettingsAndKeyframes() throws {
        let opening = try #require(imported.clip("IMG_1805.MOV", on: .video)).clip
        #expect(abs(opening.volume.value - pow(10, -6.0 / 20)) < 0.0001)
        #expect(abs(opening.transform.position.value.x - (0.5 + 10.0 / 100 / (16.0 / 9))) < 0.0001)
        #expect(abs(opening.transform.position.value.y - 0.55) < 0.0001)
        #expect(opening.transform.scale.value == 0.5)
        #expect(opening.transform.rotation.value == -90)
        // Keyframes timed in the clip's own time, which starts at 1s.
        #expect(opening.opacity.keyframes.map(\.time) == [.zero, seconds(1)])
        #expect(opening.opacity.keyframes.map(\.value) == [0, 1])
        #expect(opening.opacity.keyframes.first?.interpolation == .linear)
        #expect(opening.opacity.keyframes.last?.interpolation == .easeOut)
    }

    @Test func mapsBuiltInEffectsAndKeepsTheRest() throws {
        let opening = try #require(imported.clip("IMG_1805.MOV", on: .video)).clip
        #expect(opening.effects.contains { effect in
            if case .pan(let pan) = effect.kind { pan.position.value == -0.5 } else { false }
        })
        let blur = opening.effects.compactMap { effect -> Mosaic? in
            if case .mosaic(let mosaic) = effect.kind { mosaic } else { nil }
        }.first
        #expect(blur?.style == .blur)
        #expect(abs((blur?.scale.value ?? 0) - 0.01) < 0.000001)

        let glow = try #require(opening.effects.first { effect in
            if case .unsupported = effect.kind { true } else { false }
        })
        #expect(!glow.isEnabled)
        guard case .unsupported(let unsupported) = glow.kind else { return }
        #expect(unsupported.identifier == "com.example.fxplug.glow")
        #expect(unsupported.name == "Glow")
        #expect(unsupported.parameters == [.init(name: "Radius", key: "1", value: "12", isAnimated: true)])
        #expect(unsupported.original?.contains("<keyframe") == true)
    }

    @Test func reportsWhatDidntComeAcross() {
        let issues = imported.report.items.map(\.issue)
        #expect(issues.contains(.unsupportedEffect(name: "Glow")))
        #expect(issues.contains(.transition(name: "Cross Dissolve")))
        #expect(issues.contains(.marker(name: "Look here")))
        // The title comes in as text, so it isn't in the report.
        #expect(!issues.contains { $0 == .title })
        #expect(imported.project.tracks.flatMap(\.clips).contains { $0.content.text?.string == "Hello" })
        #expect(issues.contains(.auditionAlternatives(count: 1)))
        #expect(issues.contains(.speedChange))
        #expect(issues.contains(.disabledClip))
        // The marker is placed on the timeline: 2s into a clip starting at 1s.
        #expect(imported.report.items.first { $0.issue == .marker(name: "Look here") }?.time == seconds(1))
        #expect(imported.report.items.first { $0.issue == .unsupportedEffect(name: "Glow") }?.clipName == "Opening")
        #expect(imported.issues(.missingMedia).isEmpty)
    }
}

extension ImportedProject {
    func track(of clip: Clip) -> Int {
        project.tracks.firstIndex { $0.clip(id: clip.id) != nil }!
    }
}

struct XMEMLImportTests {
    private let imported: ImportedProject
    private let frame = CMTime(value: 1001, timescale: 30000)

    init() throws {
        imported = try InterchangeFixtures.read("Premiere.xml")
    }

    private func frames(_ count: Int64) -> CMTime {
        CMTime(value: count * 1001, timescale: 30000)
    }

    @Test func readsAGzippedFile() throws {
        for name in ["Premiere.xml", "Storylines.fcpxml"] {
            let data = try Data(contentsOf: InterchangeFixtures.directory.appending(path: name))
            let gzipped = try ProjectInterchange.read(PremiereFixtures.gzip(data))
            #expect(gzipped.project.tracks.count == (try ProjectInterchange.read(data)).project.tracks.count)
        }
    }

    @Test func takesTheSequenceSettings() {
        #expect(imported.name == "Premiere Sequence")
        #expect(imported.project.settings.frameDuration == frame)
        #expect(imported.project.settings.renderSize == CGSize(width: 1920, height: 1080))
        #expect(imported.mediaSources.values.contains(URL(fileURLWithPath: "/Volumes/Footage/IMG_1805.MOV")))
    }

    @Test func cutsInTheMiddleOfTheDissolve() throws {
        let opening = try #require(imported.clip("IMG_1805.MOV")).clip
        #expect(opening.timelineStart == .zero)
        #expect(opening.sourceRange == CMTimeRange(start: frames(30), duration: frames(150)))
        let second = try #require(imported.clip("IMG_1813.MOV")).clip
        #expect(second.timelineRange == CMTimeRange(start: frames(150), duration: frames(150)))
        #expect(second.sourceRange.start == frames(15))
    }

    @Test func joinsLinkedSoundToItsPicture() throws {
        let opening = try #require(imported.clip("IMG_1805.MOV")).clip
        #expect(!opening.isAudioDetached)
        #expect(opening.volume.value == 0.5)
        #expect(imported.clips(of: "IMG_1805.MOV").count == 1)
        // A picture whose sound isn't on the timeline plays without it.
        #expect(try #require(imported.clip("IMG_1813.MOV")).clip.isAudioDetached)
    }

    @Test func readsMotionAndOpacity() throws {
        let opening = try #require(imported.clip("IMG_1805.MOV")).clip
        #expect(opening.transform.scale.value == 0.5)
        #expect(opening.transform.rotation.value == 15)
        #expect(opening.transform.position.value == CGPoint(x: 0.75, y: 0.25))
        #expect(opening.opacity.keyframes.map(\.time) == [.zero, frames(30)])
        #expect(opening.opacity.keyframes.map(\.value) == [0, 0.8])
    }

    @Test func mapsEffectsAndKeepsTheRest() throws {
        let blurred = try #require(imported.clip("IMG_3311.MOV", on: .video))
        #expect(blurred.track == 1)
        #expect(blurred.clip.timelineRange == CMTimeRange(start: frames(30), duration: frames(60)))
        guard case .mosaic(let mosaic) = blurred.clip.effects.first?.kind else {
            Issue.record("No blur")
            return
        }
        #expect(mosaic.style == .blur)
        #expect(abs(mosaic.scale.value - 0.005) < 0.000001)
        guard case .unsupported(let lumetri) = blurred.clip.effects.last?.kind else {
            Issue.record("No unsupported effect")
            return
        }
        #expect(lumetri.identifier == "Lumetri")
        #expect(lumetri.parameters.first?.value == "0.5")
        #expect(blurred.clip.effects.last?.isEnabled == false)
    }

    @Test func keepsSoundOfItsOwnOnAnAudioTrack() throws {
        let sound = try #require(imported.clip("IMG_1841.MOV", on: .audio)).clip
        #expect(sound.timelineRange == CMTimeRange(start: .zero, duration: frames(90)))
        guard case .pan(let pan) = sound.effects.first?.kind else {
            Issue.record("No pan")
            return
        }
        #expect(pan.position.value == -1)
        #expect(imported.project.tracks.filter { $0.kind == .audio }.count == 1)
    }

    @Test func reportsWhatDidntComeAcross() {
        let issues = imported.report.items.map(\.issue)
        #expect(issues.contains(.unsupportedEffect(name: "Lumetri Color")))
        #expect(issues.contains(.transition(name: "Cross Dissolve")))
        #expect(issues.contains(.generator(name: "Color")))
        #expect(issues.contains(.marker(name: "Chapter")))
    }
}
