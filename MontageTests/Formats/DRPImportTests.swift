import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing
import UniformTypeIdentifiers

/// DaVinci Resolve projects built at test time in the layout open-source
/// readers have measured on real exports. No real export is read here.
struct DRPImportTests {
    private let imported: ImportedProject

    init() throws {
        imported = try DRPImporter.read(DRPTestBuilder().archive(), baseURL: nil)
    }

    private func frames(_ count: Int64) -> CMTime {
        CMTime(value: count, timescale: 24)
    }

    private func clipOn(_ kind: Track.Kind, at time: CMTime) -> Clip? {
        imported.project.tracks.filter { $0.kind == kind }.flatMap(\.clips).first { $0.timelineStart == time }
    }

    @Test func readsTheOpenTimelinesSettings() {
        #expect(imported.name == "Edit")
        #expect(imported.report.format == .drp)
        #expect(imported.project.settings.frameDuration == frames(1))
        #expect(imported.project.settings.renderSize == CGSize(width: 1920, height: 1080))
        #expect(imported.report.items.map(\.issue).contains(.otherTimelines(count: 1)))
    }

    @Test func readsTheMediaPool() throws {
        #expect(Set(imported.project.media.map(\.name)) == ["A001.mov", "Logo.png", "Music.wav"])
        let camera = try #require(imported.project.media.first { $0.name == "A001.mov" })
        // The media pool's path, not the timeline's older one.
        #expect(imported.mediaSources[camera.id] == URL(fileURLWithPath: "/Volumes/Media/A001.mov"))
        #expect(camera.kind == .video)
        #expect(camera.metadata.duration == CMTime(value: 20, timescale: 1))
        #expect(camera.metadata.naturalSize == CGSize(width: 3840, height: 2160))
        #expect(camera.metadata.hasAudio)
        let music = try #require(imported.project.media.first { $0.name == "Music.wav" })
        #expect(music.kind == .audio)
        #expect(imported.mediaSources[music.id] == URL(fileURLWithPath: "/Volumes/Media/Audio/Music.wav"))
        // A clip with no path in the media pool takes the timeline's.
        let logo = try #require(imported.project.media.first { $0.name == "Logo.png" })
        #expect(logo.kind == .image)
        #expect(imported.mediaSources[logo.id] == URL(fileURLWithPath: "/Users/editor/Logo.png"))
    }

    @Test func placesClipsFromTheTimelinesStart() throws {
        let opening = try #require(clipOn(.video, at: .zero))
        #expect(opening.sourceRange == CMTimeRange(start: frames(24), duration: frames(48)))
        // Its sound, linked in step on an audio track, plays with it.
        #expect(!opening.isAudioDetached)
        let logo = try #require(clipOn(.video, at: frames(12)))
        #expect(logo.sourceRange.start == .zero)
        #expect(imported.project.tracks.firstIndex { $0.clips.contains(logo) } == 1)
    }

    @Test func flattensACompoundClip() throws {
        let inner = try #require(clipOn(.video, at: frames(48)))
        #expect(inner.sourceRange == CMTimeRange(start: frames(10), duration: frames(24)))
    }

    @Test func takesWholeFramesOfAnInPointAndReportsARetime() throws {
        let retimed = try #require(clipOn(.video, at: frames(72)))
        #expect(retimed.sourceRange == CMTimeRange(start: frames(100), duration: frames(24)))
        #expect(retimed.isAudioDetached)
        #expect(imported.report.items.contains { $0.issue == .speedChange && $0.time == frames(72) })
        #expect(imported.report.items.filter { $0.issue == .speedChange }.count == 1)
    }

    @Test func putsSoundOfItsOwnOnAnAudioTrack() throws {
        let music = try #require(clipOn(.audio, at: .zero))
        #expect(music.duration == frames(96))
        #expect(imported.project.tracks.filter { $0.kind == .audio }.count == 1)
        // Its empty in point is the start of its media, and nothing to report.
        #expect(music.sourceRange.start == .zero)
        #expect(!imported.report.items.contains { $0.clipName == "Music.wav" && $0.issue != .unsupportedEffect(name: "Resolve effects") })
    }

    @Test func importsTimelineMarkers() {
        #expect(imported.project.markers.map(\.time) == [frames(24), frames(60)])
        #expect(imported.project.markers.map(\.name) == ["Cue", "Note only"])
    }

    @Test func keepsEffectsAndGradesTurnedOff() throws {
        let opening = try #require(clipOn(.video, at: .zero))
        guard case .unsupported(let grade) = opening.effects.first?.kind else {
            Issue.record("No grade")
            return
        }
        #expect(grade.name == "Color grade")
        #expect(grade.format == "drp")
        #expect(opening.effects.first?.isEnabled == false)
        let music = try #require(clipOn(.audio, at: .zero))
        #expect(music.effects.count == 1)
    }

    @Test func reportsWhatDidntComeAcross() {
        let issues = imported.report.items.map(\.issue)
        #expect(issues.contains(.transition(name: "Cross Dissolve")))
        #expect(issues.contains(.generator(name: "Solid Color")))
        #expect(issues.contains(.title))
        #expect(issues.contains(.caption))
        #expect(issues.contains(.unsupportedEffect(name: "Color grade")))
        #expect(issues.contains(.unsupportedEffect(name: "Resolve effects")))
        #expect(imported.report.items.contains { $0.issue == .marker(name: "Focus") && $0.clipName == "A001.mov" })
        #expect(!issues.contains { if case .setting = $0 { true } else { false } })
        #expect(!issues.contains(.movedToNewTrack))
        #expect(imported.report.items.first { $0.issue == .transition(name: "Cross Dissolve") }?.time == frames(36))
    }

    @Test func readsTheTimelineThatWasOpen() throws {
        var builder = DRPTestBuilder()
        builder.overrides["project.xml"] = builder.entries["project.xml"]!
            .replacingOccurrences(of: "<CurrentTimelineIndex>0<", with: "<CurrentTimelineIndex>1<")
        let alternate = try DRPImporter.read(builder.archive(), baseURL: nil)
        #expect(alternate.name == "Alternate")
        #expect(alternate.project.tracks.flatMap(\.clips).count == 1)
        #expect(alternate.project.markers.isEmpty)
        // Its empty marker blob, and a media pool clip's blob, have no markers to report.
        #expect(!alternate.report.items.contains { if case .marker = $0.issue { true } else { false } })
    }

    @Test func readsAWindowsPathsFileName() throws {
        var builder = DRPTestBuilder()
        builder.overrides["SeqContainer/0b6f0e2c-edit.xml"] = DRPTestBuilder.container(id: "c", video: [
            DRPTestBuilder.track(0, sequence: "seq-edit", items: [
                DRPTestBuilder.item("Sm2TiVideoClip", id: "i", start: 86400, duration: 24, inPoint: "0",
                                    extra: #"<MediaFilePath>D:\Footage\Day 2\B004.mov</MediaFilePath>"#),
            ]),
        ])
        let project = try DRPImporter.read(builder.archive(), baseURL: nil)
        #expect(project.project.media.map(\.name) == ["B004.mov"])
    }
}

/// Projects that can't be read, and are refused with a reason.
struct DRPRefusalTests {
    private func read(_ builder: DRPTestBuilder) throws -> ImportedProject {
        try DRPImporter.read(builder.archive(), baseURL: nil)
    }

    @Test func refusesVersionsThatHaventBeenTried() {
        var builder = DRPTestBuilder()
        builder.appVersion = "17.1.1.0009"
        builder.projectVersion = "10"
        #expect(throws: ResolveProjectError.unsupportedVersion("17.1.1.0009")) { try read(builder) }
        builder.appVersion = "22.0.0.0001"
        builder.projectVersion = "18"
        #expect(throws: ResolveProjectError.unsupportedVersion("22.0.0.0001")) { try read(builder) }
    }

    @Test func acceptsTheVersionsReadersHaveChecked() throws {
        for (app, schema) in [("19.1.4.0011", "14"), ("20.3.1.0006", "15"), ("21.1.1.0010", "17")] {
            var builder = DRPTestBuilder()
            builder.appVersion = app
            builder.projectVersion = schema
            #expect(try read(builder).name == "Edit")
        }
    }

    @Test func refusesAProjectWithNoVersion() {
        var builder = DRPTestBuilder()
        builder.projectVersion = nil
        #expect(throws: ResolveProjectError.unsupportedVersion("")) { try read(builder) }
        // Resolve 8 wrote it on the root element.
        builder.overrides["project.xml"] = #"<?xml version="1.0"?><SM_Project DbId="p" DbAppVer="8.2 (#153)"/>"#
        #expect(throws: ResolveProjectError.unsupportedVersion("8.2 (#153)")) { try read(builder) }
    }

    @Test func explainsTheRefusalAndPointsToFCPXML() {
        let error = ResolveProjectError.unsupportedVersion("17.1.1.0009")
        #expect(error.errorDescription?.contains("17.1.1.0009") == true)
        #expect(error.recoverySuggestion?.contains("FCPXML") == true)
        #expect(ResolveProjectError.unsupportedVersion("").errorDescription?.isEmpty == false)
        #expect(ResolveProjectError.damaged.errorDescription != ResolveProjectError.notAProject.errorDescription)
    }

    @Test func refusesArchivesThatArentProjects() throws {
        let other = try TestZip.archive([TestZip.File("readme.txt", "hello")])
        #expect(throws: ResolveProjectError.notAProject) { try DRPImporter.read(other, baseURL: nil) }
        var builder = DRPTestBuilder()
        builder.overrides["project.xml"] = #"<?xml version="1.0"?><!--DbAppVer="19.1.4.0011" DbPrjVer="14"--><Something/>"#
        #expect(throws: ResolveProjectError.notAProject) { try read(builder) }
    }

    @Test func refusesDamagedArchives() throws {
        let archive = DRPTestBuilder().archive()
        #expect(throws: ResolveProjectError.damaged) { try DRPImporter.read(archive.prefix(archive.count / 2), baseURL: nil) }
        var builder = DRPTestBuilder()
        builder.overrides["SeqContainer/0b6f0e2c-edit.xml"] = "<Sm2SequenceContainer><unclosed>"
        #expect(throws: ResolveProjectError.damaged) { try read(builder) }
        var corrupted = archive
        // project.xml's CRC in the central directory, whose entry has its
        // name 46 bytes in.
        let name = try #require(corrupted.range(of: Data("project.xml".utf8), options: .backwards))
        corrupted[name.lowerBound - 46 + 16] ^= 0xFF
        #expect(throws: ResolveProjectError.damaged) { try DRPImporter.read(corrupted, baseURL: nil) }
    }

    @Test func refusesAProjectWithNoTimelines() {
        var builder = DRPTestBuilder()
        builder.leaveOut = ["SeqContainer/0b6f0e2c-edit.xml", "SeqContainer/5d1c2a90-compound.xml", "SeqContainer/9e7d3b41-alt.xml"]
        #expect(throws: InterchangeError.noTimeline) { try read(builder) }
    }

    @Test func survivesBlobsThatDontDecode() throws {
        var builder = DRPTestBuilder()
        builder.overrides["MediaPool/Master/MpFolder.xml"] = builder.entries["MediaPool/Master/MpFolder.xml"]!
            .replacingOccurrences(of: "<Clip>", with: "<Clip>zz")
            .replacingOccurrences(of: "<FrameRate>", with: "<FrameRate>00")
        let project = try read(builder)
        // Without its frame rate the timeline is read at 24 fps, and the
        // report says so; without the media pool's paths, the timeline's.
        #expect(project.report.items.map(\.issue).contains(.setting(name: "Frame rate")))
        let camera = try #require(project.project.media.first { $0.name == "A001.mov" })
        #expect(project.mediaSources[camera.id] == URL(fileURLWithPath: "/Old/A001.mov"))
    }
}

/// A Resolve project read the way the apps read any project file.
struct DRPInterchangeTests {
    @Test func readsAProjectFileThroughInterchange() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Synthetic.drp")
        try DRPTestBuilder().archive().write(to: file)
        let imported = try ProjectInterchange.read(contentsOf: file)
        #expect(imported.name == "Edit")
        #expect(imported.report.format == .drp)
    }

    @Test func offersResolveProjectsForImport() {
        #expect(ProjectInterchange.importableTypes.contains(.resolveProject))
        #expect(UTType.resolveProject.identifier == "com.blackmagic-design.resolve.project")
        #expect(ProjectInterchange.importableTypes.contains(.resolveTimeline))
        #expect(UTType.resolveTimeline.identifier == "com.blackmagic-design.resolve.timeline")
    }

    /// A timeline export: a project's layout without the gallery.
    @Test func readsATimelineExport() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var builder = DRPTestBuilder()
        builder.leaveOut = ["Gallery.xml"]
        let file = folder.appending(path: "Edit.drt")
        try builder.archive().write(to: file)
        #expect(DRPImporter.isResolveArchive(builder.archive()))
        let imported = try ProjectInterchange.read(contentsOf: file)
        #expect(imported.name == "Edit")
        #expect(imported.report.format == .drp)
    }

    @Test func tellsResolveArchivesFromOtherArchives() throws {
        let other = try TestZip.archive([TestZip.File("projectData", "{}"), TestZip.File("project.xml", "<other/>")])
        #expect(!DRPImporter.isResolveArchive(other))
        #expect(!DRPImporter.isResolveArchive(Data("PK\u{3}\u{4}".utf8)))
        #expect(DRPImporter.isResolveArchive(DRPTestBuilder().archive()))
    }

    @Test func stillReadsXML() {
        #expect(throws: InterchangeError.unsupportedFormat) { try ProjectInterchange.read(Data("<html/>".utf8)) }
        #expect(throws: ResolveProjectError.damaged) { try ProjectInterchange.read(Data("PK\u{3}\u{4}".utf8)) }
    }
}
