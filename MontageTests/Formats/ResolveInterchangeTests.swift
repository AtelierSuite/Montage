import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// FCPXML as DaVinci Resolve writes it: a timeline starting at 01:00:00:00,
/// times over 24000, lanes for V2 and A1, and file://localhost URLs.
struct ResolveFCPXMLImportTests {
    private let imported: ImportedProject

    init() throws {
        imported = try InterchangeFixtures.read("Resolve.fcpxml")
    }

    private func frames(_ count: Int64) -> CMTime {
        CMTime(value: count * 1001, timescale: 24000)
    }

    @Test func takesTheTimelineSettings() {
        #expect(imported.name == "Timeline 1 (Resolve)")
        #expect(imported.project.settings.frameDuration == CMTime(value: 1001, timescale: 24000))
        #expect(imported.project.settings.renderSize == CGSize(width: 1920, height: 1080))
    }

    @Test func startsTheTimelineAtItsTimecode() throws {
        let opening = try #require(imported.clip("A001_C001.mov", on: .video)).clip
        #expect(opening.timelineStart == .zero)
        // The media's own timecode starts at 01:00:00:00 too.
        #expect(opening.sourceRange == CMTimeRange(start: frames(24), duration: frames(120)))
        #expect(!opening.isAudioDetached)
    }

    @Test func readsLocalhostURLsWithEscapedSpaces() throws {
        let item = try #require(imported.project.media.first { $0.name == "A001_C001.mov" })
        #expect(imported.mediaSources[item.id] == URL(fileURLWithPath: "/Volumes/Media/Day 1/A001_C001.mov"))
        #expect(imported.project.media.first { $0.name == "Logo.png" }?.kind == .image)
    }

    @Test func putsLanesOnTracks() throws {
        let logo = try #require(imported.clip("Logo.png", on: .video))
        #expect(logo.clip.timelineRange == CMTimeRange(start: frames(24), duration: frames(48)))
        #expect(logo.clip.opacity.value == 0.5)
        let music = try #require(imported.clip("Music.wav", on: .audio)).clip
        #expect(music.timelineRange == CMTimeRange(start: .zero, duration: frames(120)))
        #expect(abs(music.volume.value - pow(10, -6.0 / 20)) < 0.0001)
    }

    @Test func flattensTheCompoundClip() throws {
        let inner = imported.clips(of: "B002_C004.mp4").sorted { $0.timelineStart < $1.timelineStart }
        #expect(inner.first?.timelineRange == CMTimeRange(start: frames(120), duration: frames(48)))
        #expect(inner.first?.sourceRange.start == CMTime(value: 2, timescale: 1))
        // The other, connected to the gap two lanes up.
        #expect(inner.last?.timelineRange == CMTimeRange(start: frames(168), duration: frames(24)))
    }

    @Test func connectsATitleToTheGap() {
        let title = imported.project.tracks.flatMap(\.clips).first { $0.content.text != nil }
        #expect(title?.content.text?.string == "Resolve Title")
        #expect(title?.timelineRange == CMTimeRange(start: frames(192), duration: frames(48)))
    }

    @Test func reportsWhatDidntComeAcross() {
        let issues = imported.report.items.map(\.issue)
        #expect(issues.contains(.transition(name: "Cross Dissolve")))
        #expect(issues.contains(.disabledClip))
        #expect(imported.report.items.first { $0.issue == .marker(name: "Check focus") }?.time == frames(48))
        // A rate conformed without scaling isn't a speed change.
        #expect(!issues.contains(.speedChange))
        #expect(!issues.contains(.movedToNewTrack))
        #expect(imported.issues(.unsupportedEffect).isEmpty)
    }
}

/// Final Cut Pro 7 XML as DaVinci Resolve writes it: clip times from zero
/// under a 01:00:00:00 timecode, IDs with spaces and a clip item for each
/// channel of linked sound.
struct ResolveXMEMLImportTests {
    private let imported: ImportedProject

    init() throws {
        imported = try InterchangeFixtures.read("Resolve.xml")
    }

    private func frames(_ count: Int64) -> CMTime {
        CMTime(value: count, timescale: 25)
    }

    @Test func takesTheTimelineSettings() {
        #expect(imported.name == "Timeline 1")
        #expect(imported.project.settings.frameDuration == frames(1))
        #expect(imported.project.settings.renderSize == CGSize(width: 1920, height: 1080))
        #expect(imported.mediaSources.values.contains(URL(fileURLWithPath: "/Users/editor/Media/Interview A.mov")))
        #expect(imported.project.media.count == 2)
    }

    @Test func startsTheTimelineAtZero() throws {
        let interview = try #require(imported.clip("Interview A.mov", on: .video)).clip
        #expect(interview.timelineStart == .zero)
        #expect(interview.sourceRange == CMTimeRange(start: frames(25), duration: frames(125)))
        let broll = try #require(imported.clip("B-Roll.mov", on: .video)).clip
        #expect(broll.timelineRange == CMTimeRange(start: frames(125), duration: frames(150)))
    }

    @Test func joinsBothChannelsOfLinkedSoundToThePicture() throws {
        let interview = try #require(imported.clip("Interview A.mov", on: .video)).clip
        #expect(!interview.isAudioDetached)
        #expect(abs(interview.volume.value - 0.707946) < 0.000001)
        #expect(imported.clips(of: "Interview A.mov").count == 1)
        #expect(imported.project.tracks.map(\.kind) == [.video])
        #expect(try #require(imported.clip("B-Roll.mov")).clip.isAudioDetached)
    }

    @Test func readsDefaultMotionAsNoChange() throws {
        let interview = try #require(imported.clip("Interview A.mov", on: .video)).clip
        #expect(interview.transform.scale.value == 1)
        #expect(interview.transform.position.value == CGPoint(x: 0.5, y: 0.5))
        #expect(interview.opacity.value == 1)
        // A UHD clip scaled to fit the HD frame fits it, as Montage's do.
        #expect(try #require(imported.clip("B-Roll.mov")).clip.transform.scale.value == 1)
    }

    @Test func reportsWhatDidntComeAcross() {
        let issues = imported.report.items.map(\.issue)
        #expect(issues.contains(.transition(name: "Cross Dissolve")))
        #expect(imported.report.items.first { $0.issue == .marker(name: "Marker 1") }?.time == frames(50))
        #expect(!issues.contains { if case .setting = $0 { true } else { false } })
        #expect(imported.issues(.unsupportedEffect).isEmpty)
        #expect(!issues.contains(.movedToNewTrack))
    }
}

/// Quirks of Resolve's Final Cut Pro 7 XML found in real exports, in
/// minimal files of the same shape.
struct ResolveXMEMLQuirkTests {
    private func frames(_ count: Int64) -> CMTime {
        CMTime(value: count, timescale: 24)
    }

    private func sequence(_ items: String) -> Data {
        Data("""
            <xmeml version="5"><sequence><name>S</name><rate><timebase>24</timebase><ntsc>FALSE</ntsc></rate>
            <media><video><track>\(items)</track></video></media></sequence></xmeml>
            """.utf8)
    }

    private func clip(_ name: String, start: Int, end: Int, in inPoint: Int, out: Int, path: String? = nil) -> String {
        let url = path.map { "<pathurl>\($0)</pathurl>" } ?? "<pathurl></pathurl>"
        return """
            <clipitem id="\(name) 0"><name>\(name)</name><start>\(start)</start><end>\(end)</end><in>\(inPoint)</in><out>\(out)</out>
            <file id="\(name) 2"><name>\(name)</name>\(url)<media><video/></media></file></clipitem>
            """
    }

    private func dissolve(_ start: Int, _ end: Int) -> String {
        "<transitionitem><start>\(start)</start><end>\(end)</end><alignment>center</alignment><effect><name>Cross Dissolve</name></effect></transitionitem>"
    }

    /// Resolve writes a clip between two dissolves without the overlaps,
    /// so it plays from the middle of one to the middle of the other.
    @Test func placesAClipBetweenTwoDissolvesFromCutToCut() throws {
        let imported = try ProjectInterchange.read(sequence(
            dissolve(0, 24) + clip("a.mov", start: -1, end: -1, in: 24, out: 120, path: "file:///a.mov")
                + dissolve(96, 120) + clip("b.mov", start: -1, end: 216, in: 0, out: 96, path: "file:///b.mov")
        ))
        let first = try #require(imported.clip("a.mov")).clip
        #expect(first.timelineRange == CMTimeRange(start: frames(12), duration: frames(96)))
        #expect(first.sourceRange.start == frames(24))
        #expect(try #require(imported.clip("b.mov")).clip.timelineStart == frames(120))
    }

    /// Final Cut 7 and Premiere count the overlaps in, and keep their cuts.
    @Test func stillCountsOverlapsInWhereTheyreWritten() throws {
        let imported = try ProjectInterchange.read(sequence(
            dissolve(0, 24) + clip("a.mov", start: -1, end: -1, in: 24, out: 144, path: "file:///a.mov") + dissolve(96, 120)
        ))
        #expect(try #require(imported.clip("a.mov")).clip.timelineStart == .zero)
    }

    /// Resolve writes a compound clip as a file with no path, and nothing of
    /// what's inside it.
    @Test func reportsACompoundClipItLeftOut() throws {
        let imported = try ProjectInterchange.read(sequence(
            clip("a.mov", start: 0, end: 48, in: 0, out: 48, path: "file:///a.mov") + clip("E57_OUT", start: 48, end: 96, in: 0, out: 48)
        ))
        #expect(imported.project.media.map(\.name) == ["a.mov"])
        #expect(imported.report.items.contains { $0.issue == .setting(name: "Compound clip") && $0.clipName == "E57_OUT" })
        #expect(imported.issues(.missingMedia).isEmpty)
    }
}
