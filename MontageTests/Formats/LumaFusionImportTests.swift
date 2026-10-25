import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// LumaFusion packages made at test time. There are no real ones to test
/// against yet: these follow what's known of the format, a ZIP archive of a
/// JSON `*.lfarchive` and the media it uses.
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

    @Test func recognizesPackages() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = [TestZip.File("A.lfarchive", Self.projectFile(version: nil))]
        #expect(ProjectInterchange.isLumaFusionPackage(try TestZip.write(files, named: "A.lfpackage", in: folder)))
        #expect(ProjectInterchange.isLumaFusionPackage(try TestZip.write(files, named: "A.LFZ", in: folder)))
        // By content, whatever it's called.
        #expect(ProjectInterchange.isLumaFusionPackage(try TestZip.write(files, named: "A.bin", in: folder)))
        let xml = folder.appending(path: "A.fcpxml")
        try Data(Self.fcpxml.utf8).write(to: xml)
        #expect(!ProjectInterchange.isLumaFusionPackage(xml))
    }

    @Test func refusesVersionsItHasntBeenTestedWith() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let package = try Self.unpack([TestZip.File("Holiday.lfarchive", Self.projectFile(version: "5.5.2"))], in: folder)
        #expect(throws: LumaFusionError.unsupportedVersion("5.5.2")) { try LumaFusionImporter.read(package) }

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
