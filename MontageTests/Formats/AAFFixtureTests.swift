import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Files written by pyaaf2, an AAF library independent of the importer and
/// of the tests' own writer, with its full meta-dictionary, the way real
/// applications write them, one with 4096-byte sectors (pyaaf2's default)
/// and one with 512-byte sectors. Both hold the same timeline at 25 fps:
///
///     V1  Alpha 10–60 | gap 25 | Bravo 100–140 ⟍10⟋ Alpha 200–230 | Offline at half speed, 40
///     A1  Alpha 10–60 | gap 25 | Bravo 300–340 at half volume
///     a marker "Check focus" at frame 30
struct AAFFixtureTests {
    private func frames(_ count: Int64) -> CMTime { CMTime(value: count, timescale: 25) }

    @Test(arguments: ["PyAAF2-4096.aaf", "PyAAF2-512.aaf"])
    func readsFilesWrittenByPyAAF2(name: String) throws {
        let imported = try InterchangeFixtures.read(name)
        #expect(imported.report.format == .aaf)
        #expect(imported.name == "Edit One")
        #expect(imported.project.settings.frameDuration == frames(1))
        #expect(imported.project.tracks.map(\.kind) == [.video, .audio])

        let video = imported.project.tracks[0].clips
        #expect(video.map(\.timelineStart) == [.zero, frames(75), frames(110), frames(135)])
        #expect(video.map(\.sourceRange.start) == [frames(10), frames(100), frames(205), .zero])
        #expect(video.map(\.duration) == [frames(50), frames(35), frames(25), frames(40)])
        // Alpha's sound in step plays with it; elsewhere sound is detached.
        #expect(video.map(\.isAudioDetached) == [false, true, true, false])

        let audio = imported.project.tracks[1].clips
        #expect(audio.count == 1)
        #expect(audio.first?.timelineStart == frames(75))
        #expect(audio.first?.sourceRange.start == frames(300))
        #expect(audio.first?.volume.value == 0.5)

        #expect(imported.project.markers.map(\.time) == [frames(30)])
        #expect(imported.project.markers.map(\.name) == ["Check focus"])

        let names = imported.project.media.map(\.name).sorted()
        #expect(names == ["Alpha.mov", "Bravo Shot.mov", "Offline"])
        let bravo = try #require(imported.project.media.first { $0.name == "Bravo Shot.mov" })
        #expect(imported.mediaSources[bravo.id]?.path == "/Volumes/Media/Bravo Shot.mov")
        #expect(bravo.metadata.naturalSize == CGSize(width: 1920, height: 1080))

        #expect(imported.report.items.map(\.issue) == [.transition(name: "Video Dissolve"), .speedChange])
    }
}
