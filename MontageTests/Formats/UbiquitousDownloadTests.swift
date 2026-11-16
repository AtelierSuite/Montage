import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct UbiquitousDownloadTests {
    private func makeFolder() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "UbiquitousDownloadTests \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func aFileOnTheDeviceIsntPending() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Clip.mov")
        try Data([1, 2, 3]).write(to: file)
        #expect(!UbiquitousDownload.isPending(file))
    }

    @Test func aFileWithOnlyItsPlaceholderIsPending() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Clip.mov")
        try Data().write(to: UbiquitousDownload.placeholderURL(for: file))
        #expect(UbiquitousDownload.placeholderURL(for: file).lastPathComponent == ".Clip.mov.icloud")
        #expect(UbiquitousDownload.isPending(file))
    }

    @Test func aFileThatsNowhereIsntPending() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!UbiquitousDownload.isPending(folder.appending(path: "Clip.mov")))
    }

    @Test func downloadingFilesAlreadyHereEndsAtOnce() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Clip.mov")
        try Data([1, 2, 3]).write(to: file)
        var arrived: [URL] = []
        for await url in UbiquitousDownload.download([file]) { arrived.append(url) }
        #expect(arrived.isEmpty)
    }

    @Test func mediaInThePackageIsExpectedThereBeforeItArrives() throws {
        let package = URL.temporaryDirectory.appending(path: "UbiquitousDownloadTests \(UUID().uuidString).montage", directoryHint: .isDirectory)
        let store = PackageMediaStore(packageURL: package)
        let item = MediaItem(name: "Clip", kind: .video, location: .package(path: "Media/Clip.mov"), metadata: MediaMetadata())
        #expect(store.url(forPackagePath: "Media/Clip.mov") == nil)
        #expect(store.expectedURL(for: item) == package.appending(path: "Media/Clip.mov"))
    }
}
