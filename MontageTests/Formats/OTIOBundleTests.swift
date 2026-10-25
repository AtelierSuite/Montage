import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// OpenTimelineIO bundles, `.otioz` and `.otiod`, made at test time.
struct OTIOBundleTests {
    /// A timeline of one still, referred to as OTIO's bundles do: by a path
    /// relative to the bundle.
    private static let timeline = """
    {
        "OTIO_SCHEMA": "Timeline.1", "name": "", "global_start_time": {"OTIO_SCHEMA": "RationalTime.1", "rate": 24.0, "value": 0.0},
        "tracks": {"OTIO_SCHEMA": "Stack.1", "children": [{"OTIO_SCHEMA": "Track.1", "kind": "Video", "children": [{
            "OTIO_SCHEMA": "Clip.2", "name": "Tree",
            "source_range": {"OTIO_SCHEMA": "TimeRange.1",
                "start_time": {"OTIO_SCHEMA": "RationalTime.1", "rate": 24.0, "value": 0.0},
                "duration": {"OTIO_SCHEMA": "RationalTime.1", "rate": 24.0, "value": 48.0}},
            "media_references": {"DEFAULT_MEDIA": {"OTIO_SCHEMA": "ExternalReference.1", "target_url": "media/Tree.png"}},
            "active_media_reference_key": "DEFAULT_MEDIA"
        }]}]}
    }
    """

    @Test func recognisesBundles() {
        #expect(ProjectInterchange.isOTIOBundle(URL(fileURLWithPath: "/Volumes/Edit/Cut.otioz")))
        #expect(ProjectInterchange.isOTIOBundle(URL(fileURLWithPath: "/Volumes/Edit/Cut.otiod", isDirectory: true)))
        #expect(!ProjectInterchange.isOTIOBundle(URL(fileURLWithPath: "/Volumes/Edit/Cut.otio")))
        #expect(ProjectInterchange.importableTypes.contains(.otioz))
        #expect(ProjectInterchange.importableTypes.contains(.otiod))
    }

    @Test(.enabled(if: Samples.isAvailable))
    func copiesInTheMediaAnOTIOZCarries() async throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let tree = try Data(contentsOf: Samples.url("How-to-draw-a-cartoon-tree-20.png"))
        let url = try TestZip.write([
            TestZip.File("content.otio", Self.timeline, deflated: true), TestZip.File("media/Tree.png", tree),
        ], named: "Rough Cut.otioz", in: folder)

        let store = PackageMediaStore()
        let imported = try await ProjectInterchange.importOTIOBundle(at: url, into: store)
        #expect(imported.name == "Rough Cut")
        #expect(imported.report.isEmpty, "\(imported.report.items.map(\.issue))")
        let item = try #require(imported.project.media.first)
        #expect(item.kind == .image)
        #expect(try Data(contentsOf: #require(store.resolver.url(for: item))) == tree)
        #expect(imported.project.tracks.first?.clips.count == 1)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func readsAnOTIODWhereItIs() async throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = folder.appending(path: "Rough Cut.otiod", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle.appending(path: "media"), withIntermediateDirectories: true)
        try Data(Self.timeline.utf8).write(to: bundle.appending(path: "content.otio"))
        try FileManager.default.copyItem(at: Samples.url("How-to-draw-a-cartoon-tree-20.png"),
                                         to: bundle.appending(path: "media/Tree.png"))

        let store = PackageMediaStore()
        let imported = try await ProjectInterchange.importOTIOBundle(at: bundle, into: store)
        #expect(imported.name == "Rough Cut")
        #expect(imported.issues(.missingMedia).isEmpty)
        #expect(store.resolver.url(for: try #require(imported.project.media.first)) != nil)
        // Read, not moved or emptied.
        #expect(FileManager.default.fileExists(atPath: bundle.appending(path: "media/Tree.png").path))
    }

    @Test func namesMediaABundleLacksAsInTheBundle() async throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try TestZip.write([TestZip.File("content.otio", Self.timeline)], named: "Cut.otioz", in: folder)
        let imported = try await ProjectInterchange.importOTIOBundle(at: url, into: PackageMediaStore())
        #expect(imported.issues(.missingMedia) == [.missingMedia(file: url.path + "/media/Tree.png")])
    }

    @Test func refusesABundleWithoutATimeline() async throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let empty = try TestZip.write([TestZip.File("media/readme.txt", "hello")], named: "Empty.otioz", in: folder)
        await #expect(throws: InterchangeError.noTimeline) {
            try await ProjectInterchange.importOTIOBundle(at: empty, into: PackageMediaStore())
        }
        let notZip = folder.appending(path: "NotZip.otioz")
        try Data("not a zip".utf8).write(to: notZip)
        await #expect(throws: InterchangeError.self) {
            try await ProjectInterchange.importOTIOBundle(at: notZip, into: PackageMediaStore())
        }
        // Nothing unpacked is left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: URL.temporaryDirectory.path)
            .filter { $0.hasPrefix("OTIO-") && !$0.hasPrefix("OTIO-Tests") }
        #expect(leftovers.allSatisfy { name in
            !FileManager.default.fileExists(atPath: URL.temporaryDirectory.appending(path: "\(name)/media/readme.txt").path)
        })
    }
}
