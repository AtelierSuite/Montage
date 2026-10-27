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

    private static func unpack(_ files: [TestZip.File], in folder: URL, name: String = "Holiday.lfz") throws -> LumaFusionPackage {
        let url = try TestZip.write(files, named: name, in: folder)
        return try LumaFusionPackage(unpacking: url, into: folder.appending(path: "Unpacked", directoryHint: .isDirectory))
    }

    @Test func unpacksThePackage() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.unpack([
            TestZip.File("Holiday/Holiday.lfarchive", Self.projectFile(version: "5.5.2"), deflated: true),
            TestZip.File("Holiday/Media/Clip.mov", Data(repeating: 1, count: 1000)),
            TestZip.File("Holiday/Media/Music.m4a", Data(repeating: 2, count: 1000)),
        ], in: folder)
        #expect(package.projectFile?.lastPathComponent == "Holiday.lfarchive")
        #expect(package.fcpxmlFile == nil)
        #expect(package.files.count == 3)
        #expect(package.mediaFolders.map(\.lastPathComponent) == ["Unpacked", "Holiday", "Media"])
        let file = try LumaFusionProjectFile(data: Data(contentsOf: try #require(package.projectFile)))
        #expect(file.appVersion == "5.5.2")
        #expect(file.title == "Holiday")
    }

    /// Opened, only the project is unpacked, to be read before the media is.
    @Test func unpacksTheProjectBeforeTheMedia() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try TestZip.write([
            TestZip.File("__MACOSX/Holiday/._Holiday.lfarchive", "fork"),
            TestZip.File("Holiday/Media/Clip.mov", Data(repeating: 1, count: 1000)),
            TestZip.File("Holiday/Holiday.lfarchive", #"{"attributes":{"appVersion":"9.0"}}"#, deflated: true),
        ], named: "Holiday.lfz", in: folder)
        let unpacked = folder.appending(path: "Unpacked", directoryHint: .isDirectory)
        var package = try LumaFusionPackage(opening: url, into: unpacked)
        #expect(package.files.map(\.lastPathComponent) == ["Holiday.lfarchive"])
        #expect(package.projectFile?.path(percentEncoded: false).hasSuffix("Unpacked/Holiday/Holiday.lfarchive") == true)
        #expect(!FileManager.default.fileExists(atPath: unpacked.appending(path: "Holiday/Media/Clip.mov").path))
        #expect(throws: LumaFusionError.unsupportedVersion("9.0")) { try LumaFusionImporter.read(package) }
        try package.unpackMedia()
        #expect(package.files.map(\.lastPathComponent) == ["Holiday.lfarchive", "Clip.mov"])
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
        let package = try Self.unpack([TestZip.File("Holiday.lfarchive", #"{"attributes":{"appVersion":"9.0"}}"#)], in: folder)
        #expect(throws: LumaFusionError.unsupportedVersion("9.0")) { try LumaFusionImporter.read(package) }

        let unknown = try Self.unpack(
            [TestZip.File("Holiday.lfarchive", Self.projectFile(version: nil))], in: folder, name: "Unknown.lfz"
        )
        #expect(throws: LumaFusionError.unsupportedVersion(nil)) { try LumaFusionImporter.read(unknown) }

        // The message names the version and points to FCPXML.
        let error = LumaFusionError.unsupportedVersion("5.5.2")
        #expect(error.errorDescription?.contains("5.5.2") == true)
        #expect(error.recoverySuggestion?.contains("FCPXML") == true)
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
        let package = try Self.unpack([TestZip.File("Holiday.lfarchive", Self.projectFile(version: "5.5.2"))], in: folder)
        #expect(try LumaFusionImporter.read(package, decoders: [Decoder()]).name == "Holiday")
        let older = try Self.unpack(
            [TestZip.File("Holiday.lfarchive", Self.projectFile(version: "4.1"))], in: folder, name: "Older.lfz"
        )
        #expect(throws: LumaFusionError.unsupportedVersion("4.1")) { try LumaFusionImporter.read(older, decoders: [Decoder()]) }
    }

    @Test func fallsBackToTheFCPXMLItCarries() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.unpack([
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
        let package = try Self.unpack([
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
        let package = try Self.unpack([
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
        let unpacked = folder.appending(path: "Unpacked", directoryHint: .isDirectory)

        let notZip = folder.appending(path: "Text.lfz")
        try Data("not an archive".utf8).write(to: notZip)
        #expect(throws: LumaFusionError.notAPackage) { try LumaFusionPackage(unpacking: notZip, into: unpacked) }

        let whole = try TestZip.archive([TestZip.File("Holiday.lfarchive", Self.projectFile(version: "5.5.2"))])
        let truncated = folder.appending(path: "Truncated.lfz")
        try whole.prefix(whole.count - 10).write(to: truncated)
        #expect(throws: LumaFusionError.self) { try LumaFusionPackage(unpacking: truncated, into: unpacked) }

        var corrupt = whole
        corrupt[50] ^= 0xFF // inside the project file: its checksum no longer matches
        let corruptURL = folder.appending(path: "Corrupt.lfz")
        try corrupt.write(to: corruptURL)
        #expect(throws: LumaFusionError.damaged) { try LumaFusionPackage(unpacking: corruptURL, into: unpacked) }

        let notJSON = try Self.unpack([TestZip.File("Holiday.lfarchive", "bplist00")], in: folder, name: "NotJSON.lfz")
        #expect(throws: LumaFusionError.damaged) { try LumaFusionImporter.read(notJSON) }

        let empty = try Self.unpack([TestZip.File("Readme.txt", "hello")], in: folder, name: "Empty.lfz")
        #expect(throws: LumaFusionError.noProject) { try LumaFusionImporter.read(empty) }
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
        // media map.
        let project = try LumaFusionFixture.project([
            LumaFusionFixture.track(type: 0, offset: 0, anchor: true, [.init(file: "Clip.mov", start: 0, duration: 600)]),
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
