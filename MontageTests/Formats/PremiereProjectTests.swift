import Compression
import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing
import UniformTypeIdentifiers

/// The hand-made Premiere project beside the tests, and gzip to wrap it in
/// as Premiere does.
///
/// There's no corpus of projects saved by real Premiere releases yet: the
/// fixture is modelled on the structure open-source readers document, so
/// these tests check the importer against that, not against Premiere.
enum PremiereFixtures {
    static let xml = (try? String(contentsOf: InterchangeFixtures.directory.appending(path: "PremiereProject.xml"), encoding: .utf8)) ?? ""

    static let versionAttribute = #"ClassID="62ad66dd-0dcd-42da-a660-6d8fbde94876" Version="40""#

    /// The fixture, saved as if by a project of another version.
    static func xml(version: String) -> String {
        xml.replacingOccurrences(of: versionAttribute, with: #"ClassID="62ad66dd-0dcd-42da-a660-6d8fbde94876" Version="\#(version)""#)
    }

    static func read(_ xml: String = xml, baseURL: URL? = nil) throws -> ImportedProject {
        try ProjectInterchange.read(gzip(Data(xml.utf8)), baseURL: baseURL)
    }

    /// Data gzipped: a header, the data as raw DEFLATE, then its CRC-32
    /// and length.
    static func gzip(_ data: Data) -> Data {
        var output = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
        let capacity = data.count + 1024
        var compressed = Data(count: capacity)
        let size = compressed.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        output += compressed.prefix(size)
        var crc = CRC32()
        data.withUnsafeBytes { crc.update($0) }
        for word in [crc.value, UInt32(truncatingIfNeeded: data.count)] {
            output += withUnsafeBytes(of: word.littleEndian) { Data($0) }
        }
        return output
    }
}

private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
    CMTime(value: value, timescale: timescale)
}

struct PremiereProjectImportTests {
    private let imported: ImportedProject
    private let folder: URL

    init() throws {
        // The project's folder, with Interview.mov where its relative path says.
        folder = FileManager.default.temporaryDirectory.appending(path: "PremiereProjectTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appending(path: "Media"), withIntermediateDirectories: true)
        try Data().write(to: folder.appending(path: "Media/Interview.mov"))
        imported = try PremiereFixtures.read(baseURL: folder)
    }

    @Test func takesTheSequenceSettings() {
        #expect(imported.name == "Main Edit")
        #expect(imported.report.format == .prproj)
        #expect(imported.project.settings.frameDuration == CMTime(value: 1001, timescale: 30000))
        #expect(imported.project.settings.renderSize == CGSize(width: 1920, height: 1080))
    }

    @Test func picksTheFirstSequenceAndCountsTheOthersNotNested() {
        // Rough Cut is another timeline; Nested is only used inside Main Edit.
        #expect(imported.issues(.notImported).contains(.otherTimelines(count: 1)))
    }

    @Test func laysOutTracksWithTheirClipsAndTrims() throws {
        #expect(imported.project.tracks.map(\.kind) == [.video, .video, .audio])
        let interview = try #require(imported.clip("Interview.mov", on: .video))
        #expect(interview.track == 0)
        // A start Premiere leaves out is zero.
        #expect(interview.clip.timelineRange == CMTimeRange(start: .zero, duration: seconds(5)))
        #expect(interview.clip.sourceRange.start == seconds(2))

        let broll = imported.project.tracks[0].clips.filter { imported.project.mediaItem(id: $0.mediaID)?.name == "Broll.mp4" }
        #expect(broll.map(\.timelineRange) == [
            CMTimeRange(start: seconds(5), duration: seconds(3)), CMTimeRange(start: seconds(10), duration: seconds(2)),
        ])
        // At double speed, the in point is written at that speed, and the
        // clip is brought in at normal speed.
        #expect(broll.last?.sourceRange.start == seconds(2))
        #expect(imported.issues(.changed).contains(.speedChange))

        let music = try #require(imported.clip("Music.wav", on: .audio))
        #expect(music.clip.timelineRange == CMTimeRange(start: .zero, duration: seconds(12)))
    }

    @Test func keepsAClipsPictureAndSoundTogether() throws {
        let interview = try #require(imported.clip("Interview.mov", on: .video)).clip
        #expect(!interview.isAudioDetached)
        #expect(imported.clips(of: "Interview.mov").count == 1)
    }

    @Test func flattensANestedSequenceWithinItsClip() throws {
        let nested = imported.project.tracks[1].clips
        #expect(nested.count == 1)
        #expect(nested.first?.timelineRange == CMTimeRange(start: seconds(1), duration: seconds(2)))
        #expect(nested.first?.sourceRange.start == seconds(1))
    }

    @Test func makesOneMediaItemForEachFile() throws {
        #expect(imported.project.media.map(\.name).sorted() == ["Broll.mp4", "Interview.mov", "Music.wav"])
        let interview = try #require(imported.project.media.first { $0.name == "Interview.mov" })
        #expect(interview.kind == .video)
        #expect(interview.metadata.naturalSize == CGSize(width: 3840, height: 2160))
        #expect(interview.metadata.duration == seconds(60))
        #expect(interview.metadata.audioChannelCount == 2)
        #expect(abs(interview.metadata.nominalFrameRate - 30000.0 / 1001) < 0.0001)
        let music = try #require(imported.project.media.first { $0.name == "Music.wav" })
        #expect(music.kind == .audio)
        #expect(music.metadata.audioSampleRate == 44100)
    }

    @Test func findsMediaByAbsolutePathThenRelativePath() throws {
        let interview = try #require(imported.project.media.first { $0.name == "Interview.mov" })
        // The drive isn't there, so the path relative to the project is used.
        #expect(imported.mediaSources[interview.id]?.standardizedFileURL
            == folder.appending(path: "Media/Interview.mov").standardizedFileURL)
        let music = try #require(imported.project.media.first { $0.name == "Music.wav" })
        // Neither is there: the absolute path, to tell the user about.
        #expect(imported.mediaSources[music.id] == URL(fileURLWithPath: "/Users/editor/Music/Music.wav"))
        // A Windows path is of no use on this Mac; the name is looked for.
        let broll = try #require(imported.project.media.first { $0.name == "Broll.mp4" })
        #expect(imported.mediaSources[broll.id] == nil)
    }

    @Test func readsMotionAndOpacityKeyframes() throws {
        let interview = try #require(imported.clip("Interview.mov", on: .video)).clip
        #expect(interview.transform.position.value == CGPoint(x: 0.25, y: 0.5))
        // 50% of a 4K picture is the frame's own size, Montage's fitted 1.
        #expect(interview.transform.scale.value == 1)
        #expect(interview.transform.rotation.value == 90)
        // Keyframed in the media's time, 2.5s and 3.5s, which the clip
        // starts 2s into.
        #expect(interview.opacity.keyframes.map(\.time) == [seconds(1, 2), seconds(3, 2)])
        #expect(interview.opacity.keyframes.map(\.value) == [0.25, 0.75])
        #expect(interview.opacity.keyframes.map(\.interpolation) == [.linear, .hold])
    }

    @Test func readsVolumeKeyframesFromTheSoundInStep() throws {
        let interview = try #require(imported.clip("Interview.mov", on: .video)).clip
        #expect(interview.volume.keyframes.map(\.time) == [.zero, seconds(2)])
        let levels = interview.volume.keyframes.map(\.value)
        #expect(abs(levels[0] - 1) < 0.0001)
        #expect(abs(levels[1] - 0.5) < 0.0001)
    }

    @Test func mapsBuiltInEffectsAndKeepsTheRestTurnedOff() throws {
        let broll = try #require(imported.clip("Broll.mp4", on: .video)).clip
        let blur = broll.effects.compactMap { effect -> Mosaic? in
            if case .mosaic(let mosaic) = effect.kind { mosaic } else { nil }
        }.first
        #expect(blur?.style == .blur)
        #expect(abs((blur?.scale.value ?? 0) - 0.01) < 0.000001)

        let lumetri = try #require(broll.effects.first { effect in
            if case .unsupported = effect.kind { true } else { false }
        })
        #expect(!lumetri.isEnabled)
        if case .unsupported(let effect) = lumetri.kind {
            #expect(effect.format == "prproj")
            #expect(effect.identifier == "AE.ADBE Lumetri")
            #expect(effect.name == "Lumetri Color")
            #expect(effect.parameters.first == .init(name: "Exposure", key: "12", value: "1.5", isAnimated: false))
        }
        #expect(imported.issues(.unsupportedEffect) == [.unsupportedEffect(name: "Lumetri Color")])
    }

    @Test func cutsAtTransitionsAndReportsThem() throws {
        #expect(imported.report.items.contains { $0.issue == .transition(name: "Cross Dissolve") && $0.time == seconds(9, 2) })
        let interview = try #require(imported.clip("Interview.mov", on: .video)).clip
        #expect(interview.timelineRange.end == seconds(5))
    }

    @Test func bringsInSequenceMarkersAndReportsClipMarkers() throws {
        #expect(imported.project.markers.map(\.time) == [seconds(1), seconds(10)])
        #expect(imported.project.markers.map(\.name) == ["Intro", "Outro"])
        // A clip's marker inside the part used, timed on the timeline; the
        // one before the in point isn't there.
        let clipMarkers = imported.report.items.filter { if case .marker = $0.issue { true } else { false } }
        #expect(clipMarkers.map(\.issue) == [.marker(name: "Take 2")])
        #expect(clipMarkers.first?.time == seconds(1))
    }

    @Test func reportsWhatHasNoPlaceInMontage() {
        let notImported = imported.issues(.notImported)
        // The disabled clip, and the one on the muted track.
        #expect(notImported.filter { $0 == .disabledClip }.count == 2)
        #expect(notImported.contains(.generator(name: "Graphic")))
        #expect(notImported.contains(.setting(name: "Pan")))
        #expect(!notImported.contains(.setting(name: "Anchor point")))
    }

    @Test func readsTheSameProjectUncompressed() throws {
        let plain = try ProjectInterchange.read(Data(PremiereFixtures.xml.utf8), baseURL: folder)
        #expect(plain.name == "Main Edit")
        #expect(plain.project.tracks.map { $0.clips.count } == imported.project.tracks.map { $0.clips.count })
    }

    @Test func offersPremiereProjectsForImport() {
        #expect(ProjectInterchange.importableTypes.contains(.premiereProject))
        #expect(UTType.premiereProject.preferredFilenameExtension == "prproj")
    }
}

struct PremiereProjectVersionTests {
    @Test(arguments: ["37", "40", "44"])
    func readsTheVersionsItWasWrittenFor(version: String) throws {
        let imported = try PremiereFixtures.read(PremiereFixtures.xml(version: version))
        #expect(imported.name == "Main Edit")
    }

    @Test(arguments: ["1", "36", "45", "120", "forty"])
    func refusesOtherVersions(version: String) {
        #expect(throws: PremiereProjectError.unsupportedVersion) {
            try PremiereFixtures.read(PremiereFixtures.xml(version: version))
        }
    }

    @Test func refusesAProjectWithNoVersion() {
        let xml = PremiereFixtures.xml.replacingOccurrences(of: PremiereFixtures.versionAttribute, with: "")
        #expect(throws: PremiereProjectError.unsupportedVersion) { try PremiereFixtures.read(xml) }
    }

    @Test func refusesAnotherDocumentFormat() {
        let xml = PremiereFixtures.xml.replacingOccurrences(of: #"<PremiereData Version="3">"#, with: #"<PremiereData Version="4">"#)
        #expect(throws: PremiereProjectError.unsupportedVersion) { try PremiereFixtures.read(xml) }
    }

    @Test func pointsToFinalCutXMLWhenRefusing() throws {
        let error = PremiereProjectError.unsupportedVersion
        #expect(error.errorDescription?.contains("Premiere Pro") == true)
        #expect(error.recoverySuggestion?.contains("Final Cut Pro XML") == true)
    }
}

struct PremiereObjectGraphTests {
    @Test func resolvesReferencesByIDAndUIDForwardsAndBack() throws {
        let graph = try PremiereObjectGraph.read(Data(PremiereFixtures.xml.utf8)) { _ in true }
        #expect(graph.projectVersion == 40)
        #expect(graph.sequences.map { $0.child("Name")?.text } == ["Main Edit", "Nested", "Rough Cut"])
        // A forward reference by number: the sequence's video track group,
        // after its audio one as Premiere writes them.
        let group = graph.resolve(graph.sequences[0].descendant("TrackGroups")?.children("TrackGroup").last?.child("Second"))
        #expect(group?.name == "VideoTrackGroup")
        // By UID: the group's first track.
        let track = graph.resolve(group?.descendant("TrackGroup", "Tracks")?.child("Track"))
        #expect(track?["ObjectUID"] == "trk-v1")
        // A reference to nothing is nothing.
        #expect(graph.resolve(MarkupElement("Clip", [("ObjectRef", "123456")])) == nil)
        #expect(graph.resolve(nil) == nil)
    }

    @Test func indexesOnlyTopLevelObjects() throws {
        let graph = try PremiereObjectGraph.read(Data(PremiereFixtures.xml.utf8)) { _ in true }
        // The project's view state, nested with an ID of 200, is skipped
        // with the project; 200 is the clip.
        #expect(graph.objectsByID["200"]?.name == "VideoClipTrackItem")
    }

    @Test func skipsPropertyBagsAndBinaryBlobs() throws {
        let graph = try PremiereObjectGraph.read(Data(PremiereFixtures.xml.utf8)) { _ in true }
        #expect(graph.sequences[0].child("Node") == nil)
        #expect(graph.objectsByUID["media-interview"]?.child("ModificationState") == nil)
        #expect(graph.objectsByUID["media-interview"]?.child("Title")?.text == "Interview.mov")
        // Objects the importer doesn't read aren't kept at all.
        #expect(graph.objects.allSatisfy { PremiereObjectGraph.keeps($0.name) })
    }

    @Test func stopsReadingAtARefusedVersion() {
        var asked: [Int] = []
        #expect(throws: PremiereProjectError.unsupportedVersion) {
            try PremiereObjectGraph.read(Data(PremiereFixtures.xml.utf8)) { version in
                asked.append(version)
                return false
            }
        }
        #expect(asked == [40])
    }

    @Test func refusesWhatIsntAPremiereProject() {
        #expect(throws: InterchangeError.unsupportedFormat) {
            try ProjectInterchange.read(PremiereFixtures.gzip(Data("<xmeml version=\"4\"/>".utf8)))
        }
        let empty = #"<PremiereData Version="3"><Project ObjectID="1" ClassID="62ad66dd-0dcd-42da-a660-6d8fbde94876" Version="40"/></PremiereData>"#
        #expect(throws: InterchangeError.noTimeline) { try PremiereFixtures.read(empty) }
    }

    @Test func readsHugeTimesWithoutCrashing() throws {
        let xml = PremiereFixtures.xml
            .replacingOccurrences(of: "<End>1270080000000</End>", with: "<End>9223372036854775807</End>")
            .replacingOccurrences(of: "<Start>1270080000000</Start>", with: "<Start>-9223372036854775808</Start>")
            .replacingOccurrences(of: "<PlaybackSpeed>2.</PlaybackSpeed>", with: "<PlaybackSpeed>0.0000000001</PlaybackSpeed>")
        _ = try PremiereFixtures.read(xml)
    }

    @Test func stopsAtASequenceNestedInItself() throws {
        // The nested sequence's clip plays the nested sequence.
        let xml = PremiereFixtures.xml.replacingOccurrences(
            of: "<Clip ObjectRef=\"420\"/>", with: "<Clip ObjectRef=\"410\"/>"
        )
        let imported = try PremiereFixtures.read(xml)
        #expect(imported.project.tracks.count == 2)
    }
}

struct GzipInputStreamTests {
    /// Everything the stream gives, until it ends or fails.
    private func drain(_ stream: GzipInputStream, bufferSize: Int = 4096) -> Data? {
        stream.open()
        defer { stream.close() }
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let count = stream.read(&buffer, maxLength: bufferSize)
            if count < 0 { return nil }
            if count == 0 { return output }
            output.append(buffer, count: count)
        }
    }

    @Test func readsDataAcrossManyBuffers() throws {
        let original = Data((0..<400_000).map { "line \($0) of a long project\n" }.joined().utf8)
        let stream = GzipInputStream(gzipped: PremiereFixtures.gzip(original))
        #expect(drain(stream, bufferSize: 1000) == original)
        #expect(stream.failure == nil)
        #expect(stream.streamStatus == .closed)
    }

    @Test func readsAHeaderWithANameAndComment() {
        var gzipped = PremiereFixtures.gzip(Data("hello".utf8))
        // Flags for a file name and a comment, each ended by a zero.
        gzipped[3] = 0x18
        gzipped.insert(contentsOf: Data("Project.prproj\0A comment\0".utf8), at: 10)
        #expect(drain(GzipInputStream(gzipped: gzipped)) == Data("hello".utf8))
    }

    @Test func refusesTruncatedData() throws {
        let gzipped = PremiereFixtures.gzip(Data(PremiereFixtures.xml.utf8))
        for length in [5, 20, gzipped.count / 2, gzipped.count - 4] {
            let stream = GzipInputStream(gzipped: gzipped.prefix(length))
            #expect(drain(stream) == nil)
            #expect(stream.failure == .damaged)
            #expect(throws: PremiereProjectError.damaged) { try ProjectInterchange.read(gzipped.prefix(length)) }
        }
    }

    @Test func refusesCorruptData() throws {
        var gzipped = PremiereFixtures.gzip(Data(PremiereFixtures.xml.utf8))
        // A wrong checksum.
        var badChecksum = gzipped
        badChecksum[badChecksum.count - 8] ^= 0xFF
        #expect(throws: PremiereProjectError.damaged) { try ProjectInterchange.read(badChecksum) }
        // A wrong method.
        var badMethod = gzipped
        badMethod[2] = 7
        #expect(throws: PremiereProjectError.damaged) { try ProjectInterchange.read(badMethod) }
        // Damage inside the compressed data.
        for offset in stride(from: 40, to: gzipped.count - 40, by: gzipped.count / 7) {
            gzipped[offset] ^= 0x5A
        }
        #expect(throws: (any Error).self) { try ProjectInterchange.read(gzipped) }
    }
}
