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
