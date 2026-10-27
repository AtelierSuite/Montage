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
        var crc = GzipCRC32()
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

    @Test func prefersTheSequenceNamedAsTheProject() throws {
        // A CS6 feature's reel has 153 sequences, the one named as the
        // project among dozens of synced takes listed before it.
        func saved(at path: String, roughCutHasClips: Bool) -> String {
            var xml = PremiereFixtures.xml.replacingOccurrences(
                of: "<MZ.BuildVersion.Created>",
                with: "<project.settings.lastknowngoodprojectpath>\(path)</project.settings.lastknowngoodprojectpath>\n\t\t\t\t<MZ.BuildVersion.Created>"
            )
            if roughCutHasClips {
                xml = xml.replacingOccurrences(of: """
                		<TrackGroups Version="1">
                		</TrackGroups>
                		<ID>3</ID>
                """, with: """
                		<TrackGroups Version="1">
                			<TrackGroup Version="1" Index="0">
                				<First>228cda18-3625-4d2d-951e-348879e4ed93</First>
                				<Second ObjectRef="102"/>
                			</TrackGroup>
                		</TrackGroups>
                		<ID>3</ID>
                """)
            }
            return xml
        }
        #expect(try PremiereFixtures.read(saved(at: "/Volumes/Edit/Rough Cut.prproj", roughCutHasClips: true)).name == "Rough Cut")
        #expect(try PremiereFixtures.read(saved(at: #"\\?\D:\Edit\rough cut.PRPROJ"#, roughCutHasClips: true)).name == "Rough Cut")
        // Not one with nothing on it, nor without a sequence of that name.
        #expect(try PremiereFixtures.read(saved(at: "/Volumes/Edit/Rough Cut.prproj", roughCutHasClips: false)).name == "Main Edit")
        #expect(try PremiereFixtures.read(saved(at: "/Volumes/Edit/Reel 1.prproj", roughCutHasClips: true)).name == "Main Edit")
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
        #expect(!notImported.contains(.setting(name: "Pan")))
        #expect(!notImported.contains(.setting(name: "Anchor point")))
    }

    private static func pans(_ clip: Clip) -> [Pan] {
        clip.effects.compactMap { effect in
            if case .pan(let pan) = effect.kind { pan } else { nil }
        }
    }

    @Test func bringsInAStereoClipsBalance() throws {
        // 0 is full left, 0.5 centred and 1 full right: 0.75 is halfway right.
        let music = try #require(imported.clip("Music.wav", on: .audio)).clip
        #expect(Self.pans(music).map(\.position) == [Animatable(0.5)])
    }

    /// The fixture with Music.wav's panner as CS6 writes it, beside its
    /// components rather than among them, and the Panner component in its
    /// chain centred.
    private static func cs6Panner(_ processor: String, parameter: String, value: String, keyframes: String = "") -> String {
        PremiereFixtures.xml
            .replacingOccurrences(of: "-91445760000000000,0.75,", with: "-91445760000000000,0.5,")
            .replacingOccurrences(of: #"<AudioClipTrackItem ObjectID="231" ClassID="064ec682-9ba6-11d5-af2d-9ca32c7d6164" Version="6">"#, with: """
            <AudioClipTrackItem ObjectID="231" ClassID="064ec682-9ba6-11d5-af2d-9ca32c7d6164" Version="6">
            		<Panner ObjectRef="690"/>
            """)
            .replacingOccurrences(of: "<!-- Media -->", with: """
            <\(processor) ObjectID="690" ClassID="33a94283-ee2c-11d5-abc4-c1cd7f9e3c10" Version="1">
            		<PanProcessor Version="3">
            			<AudioComponent Version="3">
            				<Component Version="3">
            					<Params Version="1">
            						<Param Index="0" ObjectRef="691"/>
            					</Params>
            					<DisplayName></DisplayName>
            					<Bypass>false</Bypass>
            					<ID>4294967040</ID>
            				</Component>
            			</AudioComponent>
            		</PanProcessor>
            	</\(processor)>
            	<AudioComponentParam ObjectID="691" ClassID="a714635e-a628-4b27-9d59-77eba47dbc1a" Version="9">
            		<IsInverted>true</IsInverted>
            		<CurrentValue>\(value)</CurrentValue>
            		<StartKeyframe>-91445760000000000,\(value),0,0,0,0,0,0</StartKeyframe>
            		<Keyframes>\(keyframes)</Keyframes>
            		<Name>\(parameter)</Name>
            	</AudioComponentParam>

            	<!-- Media -->
            """)
    }

    @Test func bringsInAMonoClipsPan() throws {
        // As CS6 wrote a feature's mix: 0.25 is halfway left, whatever
        // IsInverted says.
        let xml = Self.cs6Panner("MonoToStereoPanProcessor", parameter: "Pan", value: "0.25")
        let imported = try PremiereFixtures.read(xml)
        let music = try #require(imported.clip("Music.wav", on: .audio)).clip
        #expect(Self.pans(music).map(\.position) == [Animatable(-0.5)])
        #expect(!imported.issues(.notImported).contains(.setting(name: "Pan")))
    }

    @Test func readsACS6PannersParameterWhateverItsCase() throws {
        let xml = Self.cs6Panner("MonoToStereoPanProcessor", parameter: "pan", value: "0.25")
        let music = try #require(try PremiereFixtures.read(xml).clip("Music.wav", on: .audio)).clip
        #expect(Self.pans(music).map(\.position) == [Animatable(-0.5)])
    }

    @Test func leavesACentredCS6PannerOut() throws {
        let xml = Self.cs6Panner("MonoToStereoPanProcessor", parameter: "Pan", value: "0.5")
        let music = try #require(try PremiereFixtures.read(xml).clip("Music.wav", on: .audio)).clip
        #expect(Self.pans(music).isEmpty)
    }

    @Test func keepsAStereoClipsBalanceKeyframes() throws {
        // Centred, then full right 1s into the media and full left at 3s.
        let xml = Self.cs6Panner("StereoToStereoPanProcessor", parameter: "Balance", value: "0.5",
                                 keyframes: "254016000000,1.,0,0,0,0,0,0;762048000000,0.,0,0,0,0,0,0;")
        let music = try #require(try PremiereFixtures.read(xml).clip("Music.wav", on: .audio)).clip
        let position = try #require(Self.pans(music).first).position
        #expect(position.keyframes.map(\.time) == [seconds(1), seconds(3)])
        #expect(position.keyframes.map(\.value) == [1, -1])
    }

    @Test func reportsAPannerIntoSurround() throws {
        let xml = Self.cs6Panner("StereoTo16ChannelPanProcessor", parameter: "Balance", value: "0.25")
        let imported = try PremiereFixtures.read(xml)
        let music = try #require(imported.clip("Music.wav", on: .audio)).clip
        #expect(Self.pans(music).isEmpty)
        #expect(imported.issues(.notImported).contains(.setting(name: "Pan")))
    }

    @Test func leavesACentredClipUnpanned() throws {
        let xml = PremiereFixtures.xml
            .replacingOccurrences(of: "-91445760000000000,0.75,", with: "-91445760000000000,0.5,")
        let music = try #require(try PremiereFixtures.read(xml).clip("Music.wav", on: .audio)).clip
        #expect(Self.pans(music).isEmpty)
    }

    @Test func keepsABalancesKeyframes() throws {
        // Full left 1s into the media, linear to full right at 3s.
        let xml = PremiereFixtures.xml.replacingOccurrences(
            of: "<CurrentValue>0.75</CurrentValue>",
            with: "<CurrentValue>0.75</CurrentValue>\n\t\t<Keyframes>254016000000,0.,0,0,0,0,0,0;762048000000,1.,0,0,0,0,0,0;</Keyframes>"
        )
        let music = try #require(try PremiereFixtures.read(xml).clip("Music.wav", on: .audio)).clip
        let position = try #require(Self.pans(music).first).position
        #expect(position.keyframes.map(\.time) == [seconds(1), seconds(3)])
        #expect(position.keyframes.map(\.value) == [-1, 1])
        #expect(abs(position.value(at: seconds(2))) < 0.0001)
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
    @Test(arguments: ["18", "23", "37", "40", "45"])
    func readsTheVersionsItWasWrittenFor(version: String) throws {
        let imported = try PremiereFixtures.read(PremiereFixtures.xml(version: version))
        #expect(imported.name == "Main Edit")
    }

    @Test(arguments: ["1", "17", "46", "120", "forty"])
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

/// What real projects turned up.
struct PremiereRealProjectRegressionTests {
    @Test func takesARateAHairOffStandardAsStandard() throws {
        // A 2024 project made from a phone's clip, at 30.005 fps.
        #expect(PremiereProject.frameDuration(ticksPerFrame: 8_465_845_248) == CMTime(value: 1, timescale: 30))
        #expect(PremiereProject.frameDuration(ticksPerFrame: 8_475_667_200) == CMTime(value: 1001, timescale: 30000))
        #expect(PremiereProject.frameDuration(ticksPerFrame: 10_160_640_000) == CMTime(value: 1, timescale: 25))
        // Rates that aren't near a standard one stay as they are.
        #expect(PremiereProject.frameDuration(ticksPerFrame: 16_934_400_000) == CMTime(value: 1, timescale: 15))
        #expect(PremiereProject.frameDuration(ticksPerFrame: 20_321_280_000) == CMTime(value: 2, timescale: 25))

        let xml = PremiereFixtures.xml.replacingOccurrences(
            of: "<FrameRate>8475667200</FrameRate>\n\t\t\t<NextTrackID>", with: "<FrameRate>8465845248</FrameRate>\n\t\t\t<NextTrackID>"
        )
        #expect(try PremiereFixtures.read(xml).project.settings.frameDuration == CMTime(value: 1, timescale: 30))
    }

    @Test func leavesOutGeneratedMediaWhosePathIsANumber() throws {
        // A 2025 project's Graphic: no file key, and a number for a path.
        let xml = PremiereFixtures.xml.replacingOccurrences(
            of: "<Title>Graphic</Title>\n\t\t<FileKey></FileKey>",
            with: "<FilePath>1196574294</FilePath>\n\t\t<Title>Graphic</Title>\n\t\t<Infinite>true</Infinite>\n\t\t<ActualMediaFilePath>1196574294</ActualMediaFilePath>"
        )
        let imported = try PremiereFixtures.read(xml)
        #expect(imported.issues(.notImported).contains(.generator(name: "Graphic")))
        #expect(!imported.project.media.contains { $0.name == "1196574294" || $0.name == "Graphic" })
    }

    @Test func leavesOutLinkedAfterEffectsCompositions() throws {
        // A 2024 project's Dynamic Link comp, which is an .aep file.
        let xml = PremiereFixtures.xml.replacingOccurrences(of: #"D:\Footage\Broll.mp4"#, with: #"D:\Promo\Promo.aep"#)
            .replacingOccurrences(of: "<Title>Broll.mp4</Title>", with: "<Title>Promo Linked Comp 01/Promo.aep</Title>")
        let imported = try PremiereFixtures.read(xml)
        #expect(!imported.project.media.contains { $0.name.hasSuffix(".aep") })
        #expect(imported.issues(.notImported).contains(.generator(name: "Promo Linked Comp 01/Promo.aep")))
    }

    @Test func findsUniformScaleWhereItsLeftUnnamed() throws {
        // Premiere 25 writes Motion's Uniform Scale with a blank name, as
        // parameter 4.
        let xml = PremiereFixtures.xml.replacingOccurrences(
            of: "<Name>Uniform Scale</Name>\n\t\t<ParameterID>4</ParameterID>\n\t\t<StartKeyframe>-91445760000000000,true,",
            with: "<Name> </Name>\n\t\t<ParameterID>4</ParameterID>\n\t\t<StartKeyframe>-91445760000000000,false,"
        )
        #expect(xml != PremiereFixtures.xml)
        // Scale is then the height, 50, and Scale Width 100 across, which
        // is used for both: twice the 4K picture's fit to the frame.
        let uneven = try PremiereFixtures.read(xml)
        #expect(uneven.issues(.changed).contains(.uneven(name: "Scale")))
        #expect(try #require(uneven.clip("Interview.mov", on: .video)).clip.transform.scale.value == 2)
        #expect(try !PremiereFixtures.read().issues(.changed).contains(.uneven(name: "Scale")))
    }

    @Test func findsUniformScaleInAVersion18Project() throws {
        // Premiere's version 18 numbers Motion's parameters from Scale's 1,
        // putting the unnamed Uniform Scale at 3.
        let xml = PremiereFixtures.xml
            .replacingOccurrences(of: "<Name>Scale</Name>\n\t\t<ParameterID>2</ParameterID>",
                                  with: "<Name>Scale</Name>\n\t\t<ParameterID>1</ParameterID>")
            .replacingOccurrences(of: "<Name>Scale Width</Name>\n\t\t<ParameterID>3</ParameterID>",
                                  with: "<Name>Scale Width</Name>\n\t\t<ParameterID>2</ParameterID>")
            .replacingOccurrences(
                of: "<Name>Uniform Scale</Name>\n\t\t<ParameterID>4</ParameterID>\n\t\t<StartKeyframe>-91445760000000000,true,",
                with: "<Name></Name>\n\t\t<ParameterID>3</ParameterID>\n\t\t<StartKeyframe>-91445760000000000,false,"
            )
            .replacingOccurrences(of: "<Name>Rotation</Name>\n\t\t<ParameterID>5</ParameterID>",
                                  with: "<Name>Rotation</Name>\n\t\t<ParameterID>4</ParameterID>")
        #expect(!xml.contains("<ParameterID>5</ParameterID>\n\t\t<StartKeyframe>-91445760000000000,90."))
        let imported = try PremiereFixtures.read(xml)
        #expect(imported.issues(.changed).contains(.uneven(name: "Scale")))
        #expect(try #require(imported.clip("Interview.mov", on: .video)).clip.transform.scale.value == 2)
    }

    @Test func reportsCropInMotion() throws {
        // A 2025 project wipes a still off with Motion's Crop Right, keyframed.
        let xml = PremiereFixtures.xml
            .replacingOccurrences(of: #"<Param Index="5" ObjectRef="616"/>"#,
                                  with: #"<Param Index="5" ObjectRef="616"/><Param Index="6" ObjectRef="617"/>"#)
            .replacingOccurrences(of: "<VideoFilterComponent ObjectID=\"620\"", with: """
                <VideoComponentParam ObjectID="617" ClassID="fe47129e-6c94-4fc0-95d5-c056a517aaf3" Version="10">
                <Name>Crop Right</Name><ParameterID>10</ParameterID>
                <StartKeyframe>-91445760000000000,0.,0,0,0,0,0,0</StartKeyframe><IsTimeVarying>true</IsTimeVarying>
                <Keyframes>508032000000,0.,0,0,0,0,0,0;1016064000000,100.,0,0,0,0,0,0;</Keyframes>
                </VideoComponentParam>
                <VideoFilterComponent ObjectID="620"
                """)
        #expect(try PremiereFixtures.read(xml).issues(.notImported).contains(.setting(name: "Crop")))
        #expect(try !PremiereFixtures.read().issues(.notImported).contains(.setting(name: "Crop")))
    }

    /// Music.wav with Channel Volume as a 2024 project writes it: unnamed
    /// channels past the two, at zero.
    private func channelVolume(left: String) -> String {
        PremiereFixtures.xml
            .replacingOccurrences(of: #"<Component Index="0" ObjectRef="680"/>"#,
                                  with: #"<Component Index="0" ObjectRef="680"/><Component Index="1" ObjectRef="690"/>"#)
            .replacingOccurrences(of: "<!-- A2, muted: Music.wav again -->", with: """
                <AudioFilterComponent ObjectID="690" ClassID="2d4e8c1a-0000-4000-8000-000000000690" Version="3">
                <AudioComponent Version="3"><Component Version="6"><Params Version="1">
                <Param Index="0" ObjectRef="691"/><Param Index="1" ObjectRef="692"/><Param Index="2" ObjectRef="693"/>
                </Params><ID>3</ID></Component></AudioComponent>
                <FilterMatchName>Internal Channel Volume Stereo</FilterMatchName></AudioFilterComponent>
                <AudioComponentParam ObjectID="691" Version="9"><Name>Left</Name><StartKeyframe>-91445760000000000,\(left),0,0,0,0,0,0</StartKeyframe></AudioComponentParam>
                <AudioComponentParam ObjectID="692" Version="9"><Name>Right</Name><StartKeyframe>-91445760000000000,0.177827939391,0,0,0,0,0,0</StartKeyframe></AudioComponentParam>
                <AudioComponentParam ObjectID="693" Version="9"><StartKeyframe>-91445760000000000,0.,0,0,0,0,0,0</StartKeyframe></AudioComponentParam>
                """)
    }

    @Test func reportsChannelVolumeOnlyWhereANamedChannelChanged() throws {
        let untouched = try PremiereFixtures.read(channelVolume(left: "0.177827939391"))
        #expect(!untouched.report.items.contains { if case .setting(let name) = $0.issue { name.contains("Channel") } else { false } })
        let lowered = try PremiereFixtures.read(channelVolume(left: "0.0889139697"))
        #expect(lowered.issues(.notImported).contains(.setting(name: "Channel Volume")))
    }

    @Test func namesAPlugInKnownOnlyByItsUUID() throws {
        // A 2025 project's third-party audio effect: no display name, and a
        // UUID for a match name.
        let uuid = "c6762838-e451-4d22-9c90-b0eaa734605a"
        let unnamed = PremiereProjectImporter.effectName(displayName: "", matchName: uuid, isVideo: false)
        #expect(unnamed == String(localized: "PremiereProject.UnnamedAudioEffect", bundle: Bundle(for: GzipInputStream.self)))
        #expect(unnamed != uuid && !unnamed.isEmpty)
        #expect(PremiereProjectImporter.effectName(displayName: "", matchName: "", isVideo: true)
            == String(localized: "PremiereProject.UnnamedVideoEffect", bundle: Bundle(for: GzipInputStream.self)))
        #expect(PremiereProjectImporter.effectName(displayName: "", matchName: "AE.ADBE Mirror", isVideo: true) == "AE.ADBE Mirror")
        #expect(PremiereProjectImporter.effectName(displayName: "DeEsser", matchName: uuid, isVideo: false) == "DeEsser")

        // Brought in turned off, under that name, keeping the UUID.
        let xml = PremiereFixtures.xml
            .replacingOccurrences(of: "<DisplayName>Panner</DisplayName>", with: "")
            .replacingOccurrences(of: "<FilterMatchName>Internal Panner</FilterMatchName>", with: "<FilterMatchName>\(uuid)</FilterMatchName>")
        let imported = try PremiereFixtures.read(xml)
        #expect(imported.issues(.unsupportedEffect) == [.unsupportedEffect(name: "Lumetri Color"), .unsupportedEffect(name: unnamed)])
        let music = try #require(imported.clip("Music.wav", on: .audio)).clip
        let kept = music.effects.compactMap { effect -> UnsupportedEffect? in
            if case .unsupported(let unsupported) = effect.kind { unsupported } else { nil }
        }
        #expect(kept.map(\.identifier) == [uuid])
        #expect(kept.map(\.name) == [unnamed])
    }

    @Test func timesKeyframesInTheMediaEvenForAStill() throws {
        // Premiere puts a still's in point an hour in, and its keyframes
        // with it: a 2025 project has a still from 3600.04s with keyframes
        // at 3600s and 3600.44s.
        let hour: Int64 = 3600 * PremiereProject.ticksPerSecond
        let xml = PremiereFixtures.xml
            .replacingOccurrences(of: "Interview.mov", with: "Still.jpg")
            .replacingOccurrences(of: "<InPoint>508032000000</InPoint>", with: "<InPoint>\(hour + 508_032_000_000)</InPoint>")
            .replacingOccurrences(of: "<Keyframes>635040000000,", with: "<Keyframes>\(hour + 635_040_000_000),")
            .replacingOccurrences(of: ";889056000000,", with: ";\(hour + 889_056_000_000),")
        let still = try #require(try PremiereFixtures.read(xml).clip("Still.jpg", on: .video)).clip
        #expect(still.sourceRange.start == .zero)
        #expect(still.opacity.keyframes.map(\.time) == [CMTime(value: 1, timescale: 2), CMTime(value: 3, timescale: 2)])
    }

    @Test func readsLevelsAsAFaderToPlus15dB() throws {
        // A 2025 project's music at -20 dB, a tenth of unity gain.
        let xml = PremiereFixtures.xml.replacingOccurrences(
            of: "<Keyframes>508032000000,0.17782793939113617,0,0,0,0,0,0;1016064000000,0.088913969695568085,0,0,0,0,0,0;</Keyframes>",
            with: ""
        ).replacingOccurrences(
            of: "<StartKeyframe>-91445760000000000,0.17782793939113617,", with: "<StartKeyframe>-91445760000000000,0.017782794312,"
        )
        let interview = try #require(try PremiereFixtures.read(xml).clip("Interview.mov", on: .video)).clip
        #expect(!interview.volume.isAnimated)
        #expect(abs(interview.volume.value - 0.1) < 0.00001)
        // The top of the fader, 1, is +15 dB.
        #expect(abs(1 / PremiereProjectImporter.unityLevel - pow(10, 15.0 / 20)) < 0.000001)
    }

    /// Interview.mov's motion changed, and its picture's size: the
    /// fixture's is 3840×2160 at 50%, at 0.25:0.5, turned 90°.
    private func motion(
        size: String? = nil, position: String? = nil, positionKeyframes: String? = nil, scale: String? = nil,
        rotation: String? = nil, rotationKeyframes: String? = nil, anchor: String? = nil
    ) -> String {
        var xml = PremiereFixtures.xml
        func change(_ old: String, _ new: String?) {
            guard let new else { return }
            #expect(xml.components(separatedBy: old).count == 2, "\(old) isn't in the fixture once")
            xml = xml.replacingOccurrences(of: old, with: new)
        }
        let start = "<StartKeyframe>-91445760000000000,"
        change("<FrameRect>0,0,3840,2160</FrameRect>\n\t\t<Duration>", size.map { "<FrameRect>0,0,\($0)</FrameRect>\n\t\t<Duration>" })
        change("\(start)0.25:0.5,", position.map { "\(start)\($0)," })
        change("<Name>Scale</Name>\n\t\t<ParameterID>2</ParameterID>\n\t\t\(start)50.,",
               scale.map { "<Name>Scale</Name>\n\t\t<ParameterID>2</ParameterID>\n\t\t\(start)\($0)," })
        change("<Name>Rotation</Name>\n\t\t<ParameterID>5</ParameterID>\n\t\t\(start)90.,",
               rotation.map { "<Name>Rotation</Name>\n\t\t<ParameterID>5</ParameterID>\n\t\t\(start)\($0)," })
        change("\(start)0.5:0.5,0,0,0,0,0,0,0,0,0,0,0,0</StartKeyframe>",
               anchor.map { "\(start)\($0),0,0,0,0,0,0,0,0,0,0,0,0</StartKeyframe>" })
        if let positionKeyframes {
            xml = xml.replacingOccurrences(of: #"(<Name>Position</Name>\s*<ParameterID>1</ParameterID>\s*<StartKeyframe>[^<]*</StartKeyframe>)"#,
                                           with: "$1<Keyframes>\(positionKeyframes)</Keyframes>", options: .regularExpression)
        }
        if let rotationKeyframes {
            xml = xml.replacingOccurrences(of: #"(<Name>Rotation</Name>\s*<ParameterID>5</ParameterID>\s*<StartKeyframe>[^<]*</StartKeyframe>)"#,
                                           with: "$1<Keyframes>\(rotationKeyframes)</Keyframes>", options: .regularExpression)
        }
        return xml
    }

    private func isClose(_ point: CGPoint, _ x: Double, _ y: Double) -> Bool {
        abs(point.x - x) < 0.000001 && abs(point.y - y) < 0.000001
    }

    @Test func placesAPictureNotTheFramesSizeInTheFrame() throws {
        // A 2025 project's 3888×2592 stills, fitted to a 1080p sequence's
        // height and moved right to x = 1450 px: written as 1450/1920, a
        // fraction of the sequence's frame, not of the still.
        let xml = motion(size: "3888,2592", position: "0.75520831346511841:0.5", scale: "41.666664123535", rotation: "0.")
        let still = try #require(try PremiereFixtures.read(xml).clip("Interview.mov", on: .video)).clip
        #expect(isClose(still.transform.position.value, 0.75520831346511841, 0.5))
        #expect(abs(still.transform.scale.value - 1) < 0.00001)
    }

    @Test func placesAPictureByItsAnchorPoint() throws {
        // Premiere's own tutorial project: a 500×500 still at 100% in a
        // 1080p sequence, its anchor on its bottom-left corner placed at
        // 710, 790, which puts its centre on the frame's. Its keyframes
        // move the same way.
        let xml = motion(
            size: "500,500", position: "0.36979167461395257:0.73148150973849868",
            positionKeyframes: "508032000000,-0.028645824640989304:0.73148155212402344,0,0,0,0,0,0;762048000000,0.36979167461395257:0.73148150973849868,0,0,0,0,0,0;",
            scale: "100.", rotation: "0.", anchor: "6.1035156012634317e-08:1.0000000915527323"
        )
        let imported = try PremiereFixtures.read(xml)
        let still = try #require(imported.clip("Interview.mov", on: .video)).clip
        #expect(still.transform.position.keyframes.count == 2)
        #expect(isClose(still.transform.position.keyframes[0].value, 195.0 / 1920, 0.5))
        #expect(isClose(still.transform.position.keyframes[1].value, 0.5, 0.5))
        #expect(!imported.issues(.notImported).contains(.setting(name: "Anchor point")))
    }

    @Test func turnsAPictureAboutItsAnchorPoint() throws {
        // The fixture's 4K picture at 50%, its top-left corner at 480, 540
        // and turned 90° about it: its centre, 960 across and 540 down
        // from the corner, turns to 540 left and 960 down.
        let imported = try PremiereFixtures.read(motion(anchor: "0:0"))
        let interview = try #require(imported.clip("Interview.mov", on: .video)).clip
        #expect(isClose(interview.transform.position.value, -60.0 / 1920, 1500.0 / 1080))
        #expect(interview.transform.rotation.value == 90)
        #expect(!imported.issues(.notImported).contains(.setting(name: "Anchor point")))
    }

    @Test func reportsAnAnchorPointThePictureSwingsAbout() throws {
        // Turning about a corner swings the centre round an arc, which
        // Montage's straight moves between keyframes can't follow.
        let xml = motion(rotationKeyframes: "508032000000,-90.,0,0,0,0,0,0;762048000000,0.,0,0,0,0,0,0;", anchor: "0:0")
        let imported = try PremiereFixtures.read(xml)
        let interview = try #require(imported.clip("Interview.mov", on: .video)).clip
        #expect(interview.transform.position.value == CGPoint(x: 0.25, y: 0.5))
        #expect(imported.issues(.notImported).contains(.setting(name: "Anchor point")))
    }

    @Test func refusesAProjectWithClipsButNoSequence() {
        // Media in the bin and nothing on a timeline, as in a project only
        // imported into.
        let xml = #"""
            <PremiereData Version="3"><Project ObjectID="1" ClassID="62ad66dd-0dcd-42da-a660-6d8fbde94876" Version="45"/>
            <VideoClip ObjectID="2" ClassID="9308dbef-2440-4acb-9ab2-953b9a4e82ec" Version="11"><Clip Version="18"><Source ObjectRef="3"/></Clip></VideoClip>
            <VideoMediaSource ObjectID="3" ClassID="e64ddf74-8fac-4682-8aa8-0e0ca2248949" Version="2"><MediaSource Version="4"><Media ObjectURef="m"/></MediaSource></VideoMediaSource>
            <Media ObjectUID="m" ClassID="7a5c103e-f3ac-4391-b6b4-7cc3d2f9a7ff" Version="29"><FilePath>/Media/bars.mov</FilePath><Title>bars.mov</Title><FileKey>k</FileKey></Media>
            </PremiereData>
            """#
        #expect(throws: InterchangeError.noTimeline) { try PremiereFixtures.read(xml) }
    }
}
