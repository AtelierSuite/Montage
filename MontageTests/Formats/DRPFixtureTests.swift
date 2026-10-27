import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Real Resolve projects made by others, kept in Fixtures/Resolve under
/// their own licences (see the README there), read as a user's would be.
struct DRPFixtureTests {
    private static func read(_ name: String) throws -> ImportedProject {
        let url = InterchangeFixtures.directory.appending(path: "Resolve/\(name)")
        return try DRPImporter.read(Data(contentsOf: url), baseURL: nil)
    }

    private static func notes(_ name: String, on clipName: String, in imported: ImportedProject) -> [ImportReport.Item] {
        imported.report.items.filter { $0.issue == .setting(name: name) && $0.clipName == clipName }
    }

    /// Chapter 10's "Split Screen" from Packt's Resolve 18 book (MIT). The
    /// book's Cut page shows A002_04042018_C039.mov at Position X -207.0
    /// with 37 % cropped from its right, and MVI_2573.MP4 cropped by 48 %.
    @Test func readsPacktsSplitScreen() throws {
        let imported = try Self.read("PacktSplitScreen.drp")
        #expect(imported.name == "Create_Background")
        #expect(imported.project.settings.renderSize == CGSize(width: 1920, height: 1080))
        #expect(imported.project.settings.frameDuration == CMTime(value: 1, timescale: 25))
        #expect(imported.project.media.count == 7)
        #expect(imported.project.tracks.count == 9)
        #expect(imported.project.tracks.allSatisfy { $0.kind == .video })
        #expect(imported.project.tracks.map(\.clips.count) == [1, 7, 2, 1, 1, 7, 2, 1, 1])
        #expect(imported.issues(.notImported).contains(.otherTimelines(count: 2)))

        // The split screen's left half, flattened from its compound clip
        // twice over: moved left by 207 of the timeline's 1920 pixels.
        let left = imported.clips(of: "A002_04042018_C039.mov")
        #expect(left.count == 2)
        for clip in left {
            let position = clip.transform.position.value
            #expect(abs(position.x - (0.5 - 207.0 / 1920)) < 1e-6)
            #expect(abs(position.y - 0.5) < 1e-9)
            #expect(clip.transform.scale.value == 1)
        }
        // Their crops, which Montage has no place for, are reported.
        #expect(!Self.notes("Crop", on: "A002_04042018_C039.mov", in: imported).isEmpty)
        #expect(!Self.notes("Crop", on: "MVI_2573.MP4", in: imported).isEmpty)
        #expect(imported.report.items.filter { $0.issue == .setting(name: "Crop") }.count == 4)
    }

    /// Swaraj's "leon_daddy_edit" (CC BY 4.0), made in Resolve 20.3.1:
    /// landscape gameplay stood up in a portrait timeline by a Rotation
    /// Angle of -90, and umbrella.png keyframed from 0 to 30.50009.
    @Test func readsSwarajsLeonDaddyEdit() throws {
        let imported = try Self.read("SwarajLeonDaddyEdit.drp")
        #expect(imported.name == "Timeline 1")
        #expect(imported.project.settings.renderSize == CGSize(width: 1080, height: 1920))
        #expect(imported.project.settings.frameDuration == CMTime(value: 1, timescale: 60))
        #expect(imported.project.media.count == 15)
        let video = imported.project.tracks.filter { $0.kind == .video }
        let audio = imported.project.tracks.filter { $0.kind == .audio }
        #expect(video.map(\.clips.count) == [7, 2, 3, 2, 4, 4, 1])
        #expect(audio.map(\.clips.count) == [1, 6])

        // Resolve's -90 turns anticlockwise; Montage's 90 turns clockwise.
        let clips = video.flatMap(\.clips)
        let turned = clips.filter { $0.transform.rotation == Animatable(90) }
        #expect(turned.count == 17)
        #expect(clips.filter { $0.transform.rotation != Animatable(0) }.count == 18)
        let gameplay = ["intro_daddyLeon.mkv", "leon_chappel_vid.mkv", "leon scenes.mkv", "leon_extra.mkv", "leon_bike_scene.mkv"]
        for name in gameplay {
            #expect(imported.clips(of: name).filter { video.flatMap(\.clips).contains($0) }
                .allSatisfy { $0.transform.rotation == Animatable(90) })
        }

        let umbrella = try #require(imported.clips(of: "umbrella.png").first)
        let keyframes = umbrella.transform.rotation.keyframes
        #expect(keyframes.count == 2)
        #expect(keyframes.first?.time == .zero && keyframes.first?.value == 0)
        let last = try #require(keyframes.last)
        #expect(abs(last.time.seconds - 0.95) < 1e-9)
        #expect(abs(last.value + 30.5) < 0.001)
        #expect(umbrella.transform.rotation.value == 0)
    }
}
