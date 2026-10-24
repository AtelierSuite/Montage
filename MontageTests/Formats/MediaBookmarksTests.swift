import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct MediaBookmarksTests {
    private func makeFolder() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "MediaBookmarksTests \(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func samePath(_ a: URL?, _ b: URL) -> Bool {
        a?.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }

    @Test func findsMediaLeftWhereItWas() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Clip.mov")
        try Data("not really a movie".utf8).write(to: file)

        let item = MediaItem(name: "Clip.mov", kind: .video, location: .bookmark(try MediaBookmarks.bookmark(for: file)),
                             metadata: MediaMetadata())
        let store = PackageMediaStore()
        #expect(samePath(store.resolver.url(for: item), file))
        #expect(store.bookmarks.takeRefreshedBookmarks().isEmpty)
    }

    @Test func followsAMovedFileAndRefreshesItsBookmark() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "Clip.mov")
        try Data("not really a movie".utf8).write(to: file)
        let bookmark = try MediaBookmarks.bookmark(for: file)

        let moved = folder.appending(path: "Renamed.mov")
        try FileManager.default.moveItem(at: file, to: moved)
        let bookmarks = MediaBookmarks()
        #expect(samePath(bookmarks.url(for: bookmark), moved))

        // The stale bookmark is made again, and the fresh one put in its place.
        let refreshed = bookmarks.takeRefreshedBookmarks()
        let fresh = try #require(refreshed[bookmark])
        #expect(samePath(MediaBookmarks().url(for: fresh), moved))
        var project = Project(media: [
            MediaItem(name: "Clip.mov", kind: .video, location: .bookmark(bookmark), metadata: MediaMetadata()),
        ])
        let changed = project.replaceBookmarks(refreshed)
        #expect(changed)
        #expect(project.media[0].location == .bookmark(fresh))
        #expect(bookmarks.takeRefreshedBookmarks().isEmpty)
    }

    @Test func findsNothingForADeletedFile() throws {
        let folder = try makeFolder()
        let file = folder.appending(path: "Clip.mov")
        try Data("not really a movie".utf8).write(to: file)
        let bookmark = try MediaBookmarks.bookmark(for: file)
        try FileManager.default.removeItem(at: folder)
        #expect(MediaBookmarks().url(for: bookmark) == nil)
    }
}
