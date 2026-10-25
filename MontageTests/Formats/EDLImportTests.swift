import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
    CMTime(value: value, timescale: timescale)
}

/// 29.97 frames.
private func ntsc(_ frames: Int64) -> CMTime {
    InterchangeTime.frames(frames, frameDuration: CMTime(value: 1001, timescale: 30000))!
}

struct EDLTimecodeTests {
    @Test func countsNonDropFrames() {
        let timecode = EDLTimecode("01:00:02:12")!
        #expect(timecode.frameCount(at: .fps30, dropFrame: false) == 108_072)
        #expect(EDLTimecode(frameCount: 108_072, rate: .fps30, dropFrame: false) == timecode)
        #expect(EDLTimecode("01:00:02:12")!.frameCount(at: EDLRate(frameDuration: seconds(1, 25)), dropFrame: false) == 90_062)
        #expect(EDLTimecode("nonsense") == nil)
        #expect(EDLTimecode("01:61:00:00") == nil)
    }

    @Test func countsDropFrames() {
        // Frames 00 and 01 of each minute but every tenth are skipped.
        #expect(EDLTimecode("00:01:00;02")!.frameCount(at: .ntsc30, dropFrame: true) == 1800)
        #expect(EDLTimecode("00:10:00;00")!.frameCount(at: .ntsc30, dropFrame: true) == 17_982)
        #expect(EDLTimecode("01:00:00;00")!.frameCount(at: .ntsc30, dropFrame: true) == 107_892)
        #expect(EDLTimecode(frameCount: 1800, rate: .ntsc30, dropFrame: true).string(dropFrame: true) == "00:01:00;02")
        #expect(EDLTimecode(frameCount: 1799, rate: .ntsc30, dropFrame: true).string(dropFrame: true) == "00:00:59;29")
        #expect(EDLTimecode(frameCount: 17_982, rate: .ntsc30, dropFrame: true).string(dropFrame: true) == "00:10:00;00")
        // 59.94 drops four.
        #expect(EDLTimecode("00:01:00;04")!.frameCount(at: .ntsc60, dropFrame: true) == 3600)
        for count in stride(from: 0, to: 200_000, by: 997) {
            let timecode = EDLTimecode(frameCount: count, rate: .ntsc30, dropFrame: true)
            #expect(timecode.frameCount(at: .ntsc30, dropFrame: true) == count)
        }
    }

    @Test func putsProbedRatesOnStandardOnes() {
        #expect(EDLRate.nearest(to: 29.97)?.frameDuration == CMTime(value: 1001, timescale: 30000))
        #expect(EDLRate.nearest(to: 25)?.frameDuration == seconds(1, 25))
        #expect(EDLRate.nearest(to: 23.976)?.displayString == "23.976")
        #expect(EDLRate.nearest(to: 12) == nil)
        #expect(EDLRate.ntsc30.displayString == "29.97")
    }
}

struct EDLImportTests {
    private let imported: ImportedProject

    init() throws {
        imported = try InterchangeFixtures.read("NonDropFrame.edl")
    }

    @Test func readsTheTitleAndAssumesARate() {
        #expect(imported.name == "Cut List")
        #expect(imported.report.format == .edl)
        #expect(imported.project.settings.frameDuration == seconds(1, 30))
        #expect(imported.issues(.changed).contains(.frameRateAssumed("30")))
    }

    @Test func makesMediaFromSourceFilesClipNamesAndReels() {
        let names = imported.project.media.map(\.name)
        #expect(names == ["IMG_1805.MOV", "IMG_1813.MOV", "Interview", "Tree.png"])
        let opening = imported.project.media[0]
        #expect(opening.kind == .video)
        #expect(imported.mediaSources[opening.id] == InterchangeFixtures.directory.appending(path: "IMG_1805.MOV"))
        // A reel with no file, left to be relinked.
        let interview = imported.project.media[2]
        #expect(interview.kind == .audio)
        #expect(imported.mediaSources[interview.id] == nil)
        #expect(imported.project.media[3].kind == .image)
    }

    @Test func cutsHalfwayThroughTheDissolveAndJoinsSoundInStep() throws {
        let video = try #require(imported.project.tracks.first { $0.kind == .video })
        #expect(video.clips.count == 3)
        let opening = video.clips[0]
        #expect(opening.timelineStart == .zero)
        #expect(opening.sourceRange.start == seconds(1))
        #expect(opening.duration == seconds(9, 2))
        // Its sound was a separate event of the same stretch, now played by
        // the picture's clip.
        #expect(!opening.isAudioDetached)
        let second = video.clips[1]
        #expect(second.timelineStart == seconds(9, 2))
        #expect(second.sourceRange.start == seconds(21, 2))
        #expect(second.timelineRange.end == seconds(8))
        #expect(second.isAudioDetached)
        #expect(imported.issues(.changed).contains(.transition(name: "CROSS DISSOLVE")))

        let still = video.clips[2]
        #expect(still.content == .image(imported.project.media[3].id))
        #expect(still.timelineStart == seconds(8))
        #expect(still.duration == seconds(2))
    }

    @Test func putsStereoSoundOnOneTrack() throws {
        let audio = imported.project.tracks.filter { $0.kind == .audio }
        #expect(audio.count == 1)
        let interview = try #require(audio.first?.clips.first)
        #expect(interview.timelineStart == seconds(2))
        #expect(interview.sourceRange == CMTimeRange(start: seconds(20), duration: seconds(6)))
    }

    @Test func makesLocatorsMarkers() {
        #expect(imported.project.markers.map(\.time) == [seconds(6), seconds(19, 2)])
        #expect(imported.project.markers.map(\.name) == ["Look here", ""])
    }

    @Test func readsDropFrameAt2997() throws {
        let dropFrame = try InterchangeFixtures.read("DropFrame.edl")
        #expect(dropFrame.project.settings.frameDuration == CMTime(value: 1001, timescale: 30000))
        #expect(dropFrame.issues(.changed).contains(.frameRateAssumed("29.97")))
        let video = try #require(dropFrame.project.tracks.first { $0.kind == .video })
        // Out of black: in from the middle of the dissolve.
        let first = video.clips[0]
        #expect(first.timelineStart == ntsc(15))
        #expect(first.sourceRange.start == ntsc(1800 + 15))
        // B is the picture and its sound together.
        #expect(!first.isAudioDetached)
        // 01:01:00;02 is 1800 frames into the hour.
        let last = try #require(video.clips.last)
        #expect(last.timelineStart == ntsc(1800))
        #expect(last.sourceRange.start == ntsc(600))
        #expect(last.duration == ntsc(300))
        #expect(dropFrame.project.tracks.allSatisfy { $0.kind == .video })
    }

    @Test func readsSpeedsAtNormalSpeedAndWipesAsDissolves() throws {
        let speed = try InterchangeFixtures.read("Speed.edl")
        let video = try #require(speed.project.tracks.first)
        let fast = try #require(speed.clip("Fast.mov"))
        // Kept to its length on the timeline.
        #expect(fast.clip.duration == seconds(4))
        #expect(fast.clip.sourceRange.start == .zero)
        #expect(speed.issues(.changed).filter { $0 == .speedChange }.count == 2)
        #expect(speed.issues(.changed).contains(.transition(name: "Wipe 001")))
        #expect(speed.issues(.changed).contains(.transition(name: "Dissolve")))
        // Into black, to the middle of the fade.
        #expect(video.clips.last?.timelineRange.end == seconds(10) + seconds(5, 30))
    }

    @Test func startsAListWithALeaderAtItsFirstEvent() throws {
        // Record time from 00:59:53:11, before the hour, as Avid and
        // Premiere write a list with a leader.
        let leader = try InterchangeFixtures.read("Leader.edl")
        let video = try #require(leader.project.tracks.first).clips
        #expect(video.map(\.timelineStart) == [.zero, seconds(37, 30), seconds(37 + 62, 30)])
        #expect(leader.project.duration == seconds(238, 30))
        #expect(video[0].sourceRange.start == seconds(108_125, 30))
        #expect(leader.project.markers.map(\.time) == [seconds(49, 30)])
    }

    @Test func keepsAGapAfterTheHour() throws {
        let text = "TITLE: Gap\nFCM: NON-DROP FRAME\n001  AX  V  C  00:00:00:00 00:00:01:00 01:00:05:00 01:00:06:00\n"
        let gap = try ProjectInterchange.read(Data(text.utf8))
        #expect(gap.project.tracks.first?.clips.first?.timelineStart == seconds(5))
    }

    @Test func refusesWhatIsntAnEDL() {
        #expect(throws: InterchangeError.noTimeline) { try ProjectInterchange.read(Data("TITLE: Empty\nFCM: NON-DROP FRAME\n".utf8)) }
        #expect(throws: InterchangeError.self) { try ProjectInterchange.read(Data("hello\nworld".utf8)) }
    }

    @Test func readsTheMediaRateOnceItsFound() throws {
        // The list as read at 30, then with its first file found at 25.
        var gathered = imported
        gathered.project.media[0].metadata.nominalFrameRate = 25
        gathered.project.media[0].location = .package(path: "Media/IMG_1805.MOV")
        let conform = try #require(gathered.conformToMedia)
        let conformed = conform(gathered)
        #expect(conformed.project.settings.frameDuration == seconds(1, 25))
        #expect(conformed.issues(.changed).contains(.frameRateFromMedia("25")))
        #expect(!conformed.issues(.changed).contains(.frameRateAssumed("30")))
        #expect(conformed.project.media.map(\.id) == imported.project.media.map(\.id))
        #expect(conformed.project.media[0].metadata.nominalFrameRate == 25)
        // 01:00:06:00 is still six seconds in, and 01:00:09:15 now 9.6.
        #expect(conformed.project.markers.map(\.time) == [seconds(6), seconds(48, 5)])
        let clipMedia = Set(conformed.project.tracks.flatMap(\.clips).compactMap(\.mediaID))
        #expect(clipMedia.isSubset(of: Set(imported.project.media.map(\.id))))
    }
}
