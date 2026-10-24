import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct ProjectPackageTests {
    /// A folder of its own for each test, deleted after.
    private final class Scratch {
        let directory = URL.temporaryDirectory.appending(path: "MontageTests \(UUID().uuidString)", directoryHint: .isDirectory)
        init() throws { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func file(_ name: String, bytes: Int = 64 * 1024) throws -> URL {
            let url = directory.appending(path: name)
            try Data((0..<bytes).map { UInt8($0 % 251) }).write(to: url)
            return url
        }
    }

    private func item(at path: String) -> MediaItem {
        MediaItem(name: "Clip.mov", kind: .video, location: .package(path: path),
                  metadata: MediaMetadata(duration: CMTime(value: 10, timescale: 1)))
    }

    private func write(_ wrapper: FileWrapper, to url: URL, original: URL? = nil) throws {
        try wrapper.write(to: url, options: .atomic, originalContentsURL: original)
    }

    @Test func savesStagedMediaIntoThePackage() throws {
        let scratch = try Scratch()
        let source = try scratch.file("Clip.mov")
        let store = PackageMediaStore()
        let path = try store.stage(copying: source)
        #expect(path == "Media/Clip.mov")
        // Before the first save, the staged copy is what's found.
        let project = Project(media: [item(at: path)])
        #expect(store.resolver.url(for: project.media[0]) == store.stagedURL(forPackagePath: path))

        let packageURL = scratch.directory.appending(path: "Project.montage")
        try write(ProjectPackage.fileWrapper(for: project, existing: nil, media: store), to: packageURL)
        let saved = packageURL.appending(path: path)
        #expect(FileManager.default.contentsEqual(atPath: saved.path, andPath: source.path))
        #expect(FileManager.default.fileExists(atPath: ProjectPackage.cacheDirectory(inPackageAt: packageURL).path))

        // Once saved, the package's copy is found, and the project reads back.
        store.packageURL = packageURL
        #expect(store.resolver.url(for: project.media[0])?.standardizedFileURL == saved.standardizedFileURL)
        #expect(try ProjectPackage.read(FileWrapper(url: packageURL)) == project)
    }

    @Test func keepsMediaWhenSavedAgain() throws {
        let scratch = try Scratch()
        let store = PackageMediaStore()
        let path = try store.stage(copying: scratch.file("Clip.mov"))
        var project = Project(media: [item(at: path)])
        let first = scratch.directory.appending(path: "First.montage")
        try write(ProjectPackage.fileWrapper(for: project, existing: nil, media: store), to: first)

        // Saved again elsewhere, as a move or a Save As does, from the package
        // as read, with nothing staged.
        project.settings.frameDuration = CMTime(value: 1, timescale: 25)
        let second = scratch.directory.appending(path: "Second.montage")
        let existing = try FileWrapper(url: first)
        try write(ProjectPackage.fileWrapper(for: project, existing: existing), to: second, original: first)
        #expect(FileManager.default.fileExists(atPath: second.appending(path: path).path))
        #expect(try ProjectPackage.read(FileWrapper(url: second)) == project)
    }

    @Test func leavesOutStagedMediaTheProjectNoLongerUses() throws {
        let scratch = try Scratch()
        let store = PackageMediaStore()
        _ = try store.stage(copying: scratch.file("Undone.mov"))
        let packageURL = scratch.directory.appending(path: "Project.montage")
        try write(ProjectPackage.fileWrapper(for: Project(), existing: nil, media: store), to: packageURL)
        #expect(!FileManager.default.fileExists(atPath: packageURL.appending(path: "Media/Undone.mov").path))
    }

    @Test func removesUnusedMediaOnlyWhenAsked() throws {
        let scratch = try Scratch()
        let store = PackageMediaStore()
        let path = try store.stage(copying: scratch.file("Clip.mov"))
        let packageURL = scratch.directory.appending(path: "Project.montage")
        try write(ProjectPackage.fileWrapper(for: Project(media: [item(at: path)]), existing: nil, media: store), to: packageURL)

        // The item is removed from the library: its file stays, for undo.
        let emptied = Project()
        let kept = try ProjectPackage.fileWrapper(for: emptied, existing: FileWrapper(url: packageURL))
        #expect(ProjectPackage.unusedMediaPaths(in: kept, for: emptied) == [path])

        let pruned = try ProjectPackage.fileWrapper(
            for: emptied, existing: FileWrapper(url: packageURL), removingUnusedMedia: true
        )
        let prunedURL = scratch.directory.appending(path: "Pruned.montage")
        try write(pruned, to: prunedURL, original: packageURL)
        #expect(!FileManager.default.fileExists(atPath: prunedURL.appending(path: path).path))
        #expect(ProjectPackage.unusedMediaPaths(in: pruned, for: emptied).isEmpty)
    }

    @Test func keepsTheCacheOnDiskThroughASave() throws {
        let scratch = try Scratch()
        let packageURL = scratch.directory.appending(path: "Project.montage")
        try write(ProjectPackage.fileWrapper(for: Project(), existing: nil), to: packageURL)
        // Read when the project was opened, before the cache had anything in it.
        let stale = try FileWrapper(url: packageURL)
        let thumbnail = ProjectPackage.cacheDirectory(inPackageAt: packageURL).appending(path: "thumb.jpg")
        try Data([1, 2, 3]).write(to: thumbnail)

        let store = PackageMediaStore(packageURL: packageURL)
        let wrapper = try ProjectPackage.fileWrapper(for: Project(), existing: stale, media: store)
        let savedURL = scratch.directory.appending(path: "Saved.montage")
        try write(wrapper, to: savedURL, original: packageURL)
        #expect(FileManager.default.fileExists(atPath: ProjectPackage.cacheDirectory(inPackageAt: savedURL).appending(path: "thumb.jpg").path))
    }

    @Test func opensAPackageWithoutMediaOrCache() throws {
        let scratch = try Scratch()
        let packageURL = scratch.directory.appending(path: "Project.montage")
        try FileManager.default.createDirectory(at: packageURL, withIntermediateDirectories: true)
        try Data(#"{"formatVersion": 1}"#.utf8).write(to: packageURL.appending(path: "project.json"))
        #expect(try ProjectPackage.read(FileWrapper(url: packageURL)).media.isEmpty)
    }

    @Test func makesStagedNamesUnique() throws {
        let scratch = try Scratch()
        let store = PackageMediaStore()
        let source = try scratch.file("Clip.mov")
        let first = try store.stage(copying: source)
        let second = try store.stage(copying: source)
        let third = try store.stage(copying: source, takenPaths: ["Media/Clip 3.mov"])
        #expect([first, second, third] == ["Media/Clip.mov", "Media/Clip 2.mov", "Media/Clip 4.mov"])
        // The source is left where it was.
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func discardingAStagedFileFreesItsName() throws {
        let scratch = try Scratch()
        let store = PackageMediaStore()
        let source = try scratch.file("Clip.mov")
        let path = try store.stage(copying: source)
        let staged = try #require(store.stagedURL(forPackagePath: path))
        store.discardStaged(path)
        #expect(!FileManager.default.fileExists(atPath: staged.path))
        #expect(try store.stage(copying: source) == path)
    }

    @Test func uniqueNamesIgnoreCaseAndStayInTheMediaFolder() {
        #expect(ProjectPackage.uniqueMediaPath(for: "clip.MOV", avoiding: ["Media/Clip.mov"]) == "Media/clip 2.MOV")
        #expect(ProjectPackage.uniqueMediaPath(for: "a/../b", avoiding: []) == "Media/a-..-b")
        #expect(ProjectPackage.uniqueMediaPath(for: "Notes", avoiding: ["Media/Notes"]) == "Media/Notes 2")
    }
}
