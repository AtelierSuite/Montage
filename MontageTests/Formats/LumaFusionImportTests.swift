import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// LumaFusion packages made at test time, laid out as real ones are: a ZIP
/// archive of a JSON `*.lfarchive` and the media it uses.
struct LumaFusionImportTests {
    private static func projectFile(version: String?) -> String {
        let attributes = version.map { #"{"appVersion":"\#($0)"}"# } ?? "{}"
        return #"{"title":"Holiday","attributes":\#(attributes),"tracks":[]}"#
    }

    /// An FCPXML document using one clip, by a relative path.
    private static let fcpxml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <fcpxml version="1.10">
      <resources>
        <format id="r1" frameDuration="1001/30000s" width="1920" height="1080"/>
        <asset id="r2" name="Clip" start="0s" duration="10s" hasVideo="1" format="r1">
          <media-rep kind="original-media" src="Media/Clip.mov"/>
        </asset>
      </resources>
      <library>
        <event name="Event">
          <project name="Holiday">
            <sequence format="r1" duration="5s">
              <spine>
                <asset-clip ref="r2" name="Clip" offset="0s" start="0s" duration="5s"/>
              </spine>
            </sequence>
          </project>
        </event>
      </library>
    </fcpxml>
    """

    private static func open(_ files: [TestZip.File], in folder: URL, name: String = "Holiday.lfz") throws -> LumaFusionPackage {
        try LumaFusionPackage(reading: try TestZip.write(files, named: name, in: folder))
    }

    @Test func readsThePackageWhereItIs() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.open([
            TestZip.File("Holiday/Holiday.lfarchive", Self.projectFile(version: "5.5.2"), deflated: true),
            TestZip.File("Holiday/Media/Clip.mov", Data(repeating: 1, count: 1000)),
            TestZip.File("Holiday/Media/Music.m4a", Data(repeating: 2, count: 1000)),
            // Passed over: outside the package, and Finder's resource forks.
            TestZip.File("../Escaped.mov", "out"),
            TestZip.File("__MACOSX/Holiday/._Clip.mov", "fork"),
            TestZip.File("Holiday/._Music.m4a", "fork"),
        ], in: folder)
        #expect(package.projectFile?.fileName == "Holiday.lfarchive")
        #expect(package.fcpxmlFile == nil)
        #expect(package.files.map(\.fileName) == ["Holiday.lfarchive", "Clip.mov", "Music.m4a"])
        #expect(package.folder.standardizedFileURL == folder.standardizedFileURL)
        // Nothing is unpacked beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Holiday.lfz"])
        let file = try LumaFusionProjectFile(data: package.data(of: try #require(package.projectFile), limit: 1 << 20))
        #expect(file.appVersion == "5.5.2")
        #expect(file.title == "Holiday")
        #expect(package.file(at: ["Holiday", "Media", "Clip.mov"])?.path == "Holiday/Media/Clip.mov")
        #expect(package.file(namedAnyOf: ["Missing.mov", "Music.m4a"])?.path == "Holiday/Media/Music.m4a")
        #expect(package.file(namedAnyOf: ["Escaped.mov"]) == nil)
    }

    @Test func recognizesPackages() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [TestZip.File("A.lfarchive", Self.projectFile(version: nil))]
        #expect(ProjectInterchange.isLumaFusionPackage(try TestZip.write(files, named: "A.lfpackage", in: folder)))
        #expect(ProjectInterchange.isLumaFusionPackage(try TestZip.write(files, named: "A.LFZ", in: folder)))
        // By content, whatever it's called.
        #expect(ProjectInterchange.isLumaFusionPackage(try TestZip.write(files, named: "A.bin", in: folder)))
        // Other formats are ZIP archives too, such as DaVinci Resolve's
        // projects: only one with a LumaFusion project file in it is taken.
        let resolve = [TestZip.File("project.xml", "<project/>"), TestZip.File("Media/Clip.mov", "clip")]
        #expect(!ProjectInterchange.isLumaFusionPackage(try TestZip.write(resolve, named: "A.drp", in: folder)))
        #expect(!ProjectInterchange.isLumaFusionPackage(try TestZip.write(resolve, named: "A.zip", in: folder)))
        let xml = folder.appending(path: "A.fcpxml")
        try Data(Self.fcpxml.utf8).write(to: xml)
        #expect(!ProjectInterchange.isLumaFusionPackage(xml))
    }

    @Test func refusesProjectsItCantRead() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Laid out as no version of LumaFusion this was written against.
        let package = try Self.open([TestZip.File("Holiday.lfarchive", #"{"attributes":{"appVersion":"9.0"}}"#)], in: folder)
        #expect(throws: LumaFusionError.unsupportedVersion("9.0")) { try LumaFusionImporter.read(package) }

        let unknown = try Self.open(
            [TestZip.File("Holiday.lfarchive", Self.projectFile(version: nil))], in: folder, name: "Unknown.lfz"
        )
        #expect(throws: LumaFusionError.unsupportedVersion(nil)) { try LumaFusionImporter.read(unknown) }

        // The message names the version and points to FCPXML.
        let error = LumaFusionError.unsupportedVersion("5.5.2")
        #expect(error.errorDescription?.contains("5.5.2") == true)
        #expect(error.recoverySuggestion?.contains("FCPXML") == true)
    }

    @Test func refusesProjectsFromOlderVersions() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // As LumaFusion for iOS 3.0.9 and earlier wrote them: the project a
        // keyed archive, names in UTF-8 without the flag that says so, and
        // the same file listed twice.
        let keyedArchive = Data("bplist00".utf8) + Data(repeating: 0, count: 32)
        let files = [
            TestZip.File("Tammy’s Title.spryArchive", keyedArchive, deflated: true, utf8Flag: false),
            TestZip.File("Fonts/Title.ttf", "font", deflated: true, utf8Flag: false),
            TestZip.File("Fonts/Title.ttf", "font", deflated: true, utf8Flag: false),
        ]
        for name in ["Tammy’s Title.lfpackage", "Intro.spryzip", "Intro.SPRYZIP", "Intro.bin"] {
            #expect(ProjectInterchange.isLumaFusionPackage(try TestZip.write(files, named: name, in: folder)))
        }
        let package = try Self.open(files, in: folder, name: "Intro.spryzip")
        #expect(package.keyedArchiveFile?.fileName == "Tammy’s Title.spryArchive")
        // The file listed twice is one file.
        #expect(package.files.count == 2)
        #expect(package.projectFile == nil)
        #expect(throws: LumaFusionError.olderVersion) { try LumaFusionImporter.read(package) }

        // A keyed archive under the JSON project's name.
        let renamed = try Self.open([TestZip.File("Intro.lfarchive", keyedArchive)], in: folder, name: "Renamed.lfz")
        #expect(throws: LumaFusionError.olderVersion) { try LumaFusionImporter.read(renamed) }

        // Its own message, which says what to do.
        let error = LumaFusionError.olderVersion
        #expect(error.errorDescription != LumaFusionError.noProject.errorDescription)
        #expect(error.errorDescription != LumaFusionError.unsupportedVersion(nil).errorDescription)
        #expect(error.recoverySuggestion?.contains("LumaFusion") == true)
    }

    @Test func handsSupportedVersionsToTheirDecoder() throws {
        struct Decoder: LumaFusionProjectDecoder {
            func supports(appVersion: String) -> Bool { appVersion.hasPrefix("5.") }
            func decode(_ file: LumaFusionProjectFile, in package: LumaFusionPackage) throws -> ImportedProject {
                ImportedProject(project: Project(), report: ImportReport(format: .fcpxml), name: file.title, mediaSources: [:])
            }
        }
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.open([TestZip.File("Holiday.lfarchive", Self.projectFile(version: "5.5.2"))], in: folder)
        #expect(try LumaFusionImporter.read(package, decoders: [Decoder()]).name == "Holiday")
        let older = try Self.open(
            [TestZip.File("Holiday.lfarchive", Self.projectFile(version: "4.1"))], in: folder, name: "Older.lfz"
        )
        #expect(throws: LumaFusionError.unsupportedVersion("4.1")) { try LumaFusionImporter.read(older, decoders: [Decoder()]) }
    }

    @Test func fallsBackToTheFCPXMLItCarries() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.open([
            TestZip.File("Holiday.lfarchive", Self.projectFile(version: "9.0")),
            TestZip.File("Holiday.fcpxml", Self.fcpxml),
        ], in: folder)
        let imported = try LumaFusionImporter.read(package)
        #expect(imported.name == "Holiday")
        #expect(imported.project.media.map(\.name) == ["Clip.mov"])
    }

    /// The FCPXML document's timeline as LumaFusion's own project file.
    private static func nativeProject() throws -> Data {
        try LumaFusionFixture.project([
            LumaFusionFixture.track(type: 0, offset: 0, anchor: true, [.init(file: "Clip.mov", start: 0, duration: 3000)]),
        ], resolution: [1920, 1080], step: LumaFusionFixture.time(1001, 30000))
    }

    @Test func readsItsOwnProjectWithoutFCPXML() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.open([
            TestZip.File("Holiday.lfarchive", try Self.nativeProject(), deflated: true),
            TestZip.File("Clip.mov", Data(repeating: 1, count: 1000)),
        ], in: folder)
        let imported = try LumaFusionImporter.read(package)
        #expect(imported.report.format == .lumaFusion)
        #expect(imported.name == "Holiday")
        #expect(imported.project.media.map(\.name) == ["Clip.mov"])
        #expect(imported.project.tracks.flatMap(\.clips).count == 1)
    }

    /// Where a package carries both, the FCPXML is read, and LumaFusion's
    /// own project file comes out the same.
    @Test func crossChecksItsOwnProjectAgainstFCPXML() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.open([
            TestZip.File("Holiday.lfarchive", try Self.nativeProject()),
            TestZip.File("Holiday.fcpxml", Self.fcpxml),
        ], in: folder)
        let fromFCPXML = try LumaFusionImporter.read(package)
        #expect(fromFCPXML.report.format == .fcpxml)
        let native = try LumaFusionTimelineReader.read(try Self.nativeProject(), appVersion: "2.6.0")

        func summary(_ imported: ImportedProject) -> [String] {
            imported.project.tracks.flatMap { track in
                track.clips.map { clip in
                    "\(track.kind) \(imported.project.mediaItem(id: clip.mediaID)?.name ?? "") \(clip.timelineStart.seconds) "
                        + "\(clip.sourceRange.start.seconds) \(clip.duration.seconds)"
                }
            }
        }
        #expect(summary(native) == summary(fromFCPXML))
        #expect(native.name == fromFCPXML.name)
        #expect(native.project.settings == fromFCPXML.project.settings)
    }

    @Test func refusesMalformedPackages() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let notZip = folder.appending(path: "Text.lfz")
        try Data("not an archive".utf8).write(to: notZip)
        #expect(throws: LumaFusionError.notAPackage) { try LumaFusionPackage(reading: notZip) }

        let whole = try TestZip.archive([TestZip.File("Holiday.lfarchive", Self.projectFile(version: "5.5.2"))])
        let truncated = folder.appending(path: "Truncated.lfz")
        try whole.prefix(whole.count - 10).write(to: truncated)
        #expect(throws: LumaFusionError.self) { try LumaFusionPackage(reading: truncated) }

        var corrupt = whole
        corrupt[50] ^= 0xFF // inside the project file: its checksum no longer matches
        let corruptURL = folder.appending(path: "Corrupt.lfz")
        try corrupt.write(to: corruptURL)
        // Found when the project file is read.
        let corruptPackage = try LumaFusionPackage(reading: corruptURL)
        #expect(throws: LumaFusionError.damaged) { try LumaFusionImporter.read(corruptPackage) }

        let notJSON = try Self.open([TestZip.File("Holiday.lfarchive", "{\"tracks\": [")], in: folder, name: "NotJSON.lfz")
        #expect(throws: LumaFusionError.damaged) { try LumaFusionImporter.read(notJSON) }

        let empty = try Self.open([TestZip.File("Readme.txt", "hello")], in: folder, name: "Empty.lfz")
        #expect(throws: LumaFusionError.noProject) { try LumaFusionImporter.read(empty) }
    }

    @Test func unpacksTheMediaItUsesStraightIntoStaging() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Two files whose names differ only in case, which a folder on a
        // file system that ignores case couldn't hold side by side, and one
        // the project doesn't use.
        let project = try LumaFusionFixture.project([
            LumaFusionFixture.track(type: 0, offset: 0, anchor: true, [
                .init(file: "A", start: 0, duration: 600), .init(file: "B", start: 600, duration: 600),
            ]),
        ], mediaMap: ["Clip.MOV": LumaFusionFixture.assetID("A"), "clip.mov": LumaFusionFixture.assetID("B")])
        let package = try Self.open([
            TestZip.File("Holiday.lfarchive", project, deflated: true),
            TestZip.File("Clip.MOV", "upper", deflated: true),
            TestZip.File("clip.mov", "lower"),
            TestZip.File("Unused.mov", "unused"),
        ], in: folder)
        let imported = try LumaFusionImporter.read(package)
        let store = PackageMediaStore()
        let staged = try LumaFusionImporter.stageMedia(for: imported, from: package, into: store)
        let contents = try imported.project.media.map { item in
            let path = try #require(staged[item.id])
            let url = try #require(store.stagedURL(forPackagePath: path))
            return String(decoding: try Data(contentsOf: url), as: UTF8.self)
        }
        #expect(contents == ["upper", "lower"])
        #expect(Set(staged.values).count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path).count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["Holiday.lfz"])
    }

    @Test func stagesNothingFromAPackageWhoseMediaIsDamaged() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let project = try LumaFusionFixture.project([
            LumaFusionFixture.track(type: 0, offset: 0, anchor: true, [
                .init(file: "A.mov", start: 0, duration: 600), .init(file: "B.mov", start: 600, duration: 600),
            ]),
        ])
        let files = [
            TestZip.File("Holiday.lfarchive", project),
            TestZip.File("A.mov", "a"),
            TestZip.File("B.mov", String(repeating: "b", count: 100)),
        ]
        var data = try TestZip.archive(files)
        // Inside B.mov, past the local records before it and its own header:
        // its checksum no longer matches.
        let before = files.prefix(2).reduce(0) { $0 + 30 + $1.path.utf8.count + $1.data.count }
        data[before + 30 + "B.mov".utf8.count + 50] ^= 0xFF
        let url = folder.appending(path: "Holiday.lfz")
        try data.write(to: url)
        let package = try LumaFusionPackage(reading: url)
        let imported = try LumaFusionImporter.read(package)
        let store = PackageMediaStore()
        #expect(throws: LumaFusionError.damaged) {
            try LumaFusionImporter.stageMedia(for: imported, from: package, into: store)
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: store.stagingDirectory.path)) ?? []).isEmpty)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func copiesInTheMediaThePackageCarries() async throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try Data(contentsOf: Samples.url("IMG_1805.MOV"))
        // Put somewhere other than where the FCPXML says, as the package's
        // layout isn't known: it's found by name.
        let url = try TestZip.write([
            TestZip.File("Holiday/Holiday.fcpxml", Self.fcpxml),
            TestZip.File("Holiday/Assets/Clip.mov", clip),
        ], named: "Holiday.lfz", in: folder)

        let store = PackageMediaStore()
        let imported = try await ProjectInterchange.importLumaFusionPackage(at: url, into: store)
        #expect(imported.issues(.missingMedia).isEmpty)
        let item = try #require(imported.project.media.first)
        let staged = try #require(store.resolver.url(for: item))
        #expect(try Data(contentsOf: staged) == clip)
        #expect(item.kind == .video)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func copiesInTheMediaItsOwnProjectUses() async throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clip = try Data(contentsOf: Samples.url("IMG_1805.MOV"))
        // As LumaFusion stores it: beside the project file, named in its
        // media map, with where it was on the device that made it as well.
        let project = try LumaFusionFixture.project([
            LumaFusionFixture.track(type: 0, offset: 0, anchor: true, [
                .init(file: "Clip.mov", start: 0, duration: 600, originalFilename: "/var/mobile/Media/DCIM/IMG_0001.MOV"),
            ]),
        ], mediaMap: ["IMG_1805.MOV": LumaFusionFixture.assetID("Clip.mov")])
        let url = try TestZip.write([
            TestZip.File("Holiday.lfarchive", project, deflated: true),
            TestZip.File("IMG_1805.MOV", clip, deflated: true),
        ], named: "Holiday.lfpackage", in: folder)

        let store = PackageMediaStore()
        let imported = try await ProjectInterchange.importLumaFusionPackage(at: url, into: store)
        #expect(imported.issues(.missingMedia).isEmpty)
        let item = try #require(imported.project.media.first)
        #expect(item.name == "IMG_1805.MOV")
        #expect(item.kind == .video)
        #expect(try Data(contentsOf: try #require(store.resolver.url(for: item))) == clip)
    }

    @Test func leavesMediaThePackageLacksReadyToRelink() async throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try TestZip.write([TestZip.File("Holiday.fcpxml", Self.fcpxml)], named: "Holiday.lfz", in: folder)
        let store = PackageMediaStore()
        let imported = try await ProjectInterchange.importLumaFusionPackage(at: url, into: store)
        #expect(imported.issues(.missingMedia).count == 1)
        let item = try #require(imported.project.media.first)
        #expect(store.resolver.url(for: item) == nil)
    }
}
