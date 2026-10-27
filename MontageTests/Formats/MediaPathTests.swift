import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Media paths as other editors write them, read as file URLs whose last
/// component names the file, so it can be looked for by name.
struct MediaPathTests {
    @Test(arguments: [
        ("D:\\NextCloud\\Rushes\\Camera\\MTC_2206.MP4", "/D:/NextCloud/Rushes/Camera/MTC_2206.MP4"),
        ("C:/Users/editor/Desktop/clip.mov", "/C:/Users/editor/Desktop/clip.mov"),
        ("\\\\server\\share\\Media\\clip.mov", "/Volumes/share/Media/clip.mov"),
        ("file:///C:%5CUsers%5Ceditor%5Cclip.mov", "/C:/Users/editor/clip.mov"),
        ("file://localhost/C:/Media/clip.mov", "/C:/Media/clip.mov"),
        ("D:\\Media\\my%20clip.mov", "/D:/Media/my clip.mov"),
        ("\\\\nas\\Footage\\my%20clip.mov", "/Volumes/Footage/my clip.mov"),
    ])
    func readsWindowsPaths(reference: String, path: String) throws {
        let url = try #require(ImportedMedia.url(from: reference, relativeTo: nil))
        #expect(url.isFileURL)
        #expect(url.path == path)
        #expect(url.lastPathComponent == (path as NSString).lastPathComponent)
    }

    @Test func readsRelativeWindowsPathsFromBesideTheFile() throws {
        let base = URL(fileURLWithPath: "/Projects/Edit/")
        let url = try #require(ImportedMedia.url(from: "Media\\clip.mov", relativeTo: base))
        #expect(url.path == "/Projects/Edit/Media/clip.mov")
    }

    @Test func leavesOtherPathsAlone() throws {
        #expect(ImportedMedia.url(from: "/Volumes/Media/clip.mov", relativeTo: nil)?.path == "/Volumes/Media/clip.mov")
        #expect(ImportedMedia.url(from: "file:///Users/editor/clip%20one.mov", relativeTo: nil)?.path == "/Users/editor/clip one.mov")
        #expect(ImportedMedia.url(from: "file://localhost/Volumes/A/clip.mov", relativeTo: nil)?.path == "/Volumes/A/clip.mov")
        #expect(ImportedMedia.url(from: "https://example.com/clip.mov", relativeTo: nil)?.scheme == "https")
    }

    @Test(arguments: [
        ("D:\\NextCloud\\Rushes\\MTC_2206.MP4", "D:\\NextCloud\\Rushes\\MTC_2206.MP4"),
        ("file:///C:/Media/my%20clip.mov", "C:\\Media\\my clip.mov"),
        ("\\\\server\\share\\clip.mov", "\\\\server\\share\\clip.mov"),
    ])
    func keepsWindowsPathsAsWrittenToShow(reference: String, written: String) throws {
        let reference = try #require(ImportedMedia.reference(from: reference, relativeTo: nil))
        #expect(reference.writtenPath == written)
        #expect(reference.ignoresCase)
    }

    @Test func readsMixedSlashRelativePathsFromBesideTheFile() throws {
        let base = URL(fileURLWithPath: "/Projects/Edit/")
        #expect(ImportedMedia.url(from: "Media/Sub\\clip.mov", relativeTo: base)?.path == "/Projects/Edit/Media/Sub/clip.mov")
        #expect(ImportedMedia.url(from: "./Media\\clip.mov", relativeTo: base)?.path == "/Projects/Edit/Media/clip.mov")
    }

    @Test func keepsBackslashesInNamesOfFilesThatExist() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(path: "take\\1.mov"))
        let url = try #require(ImportedMedia.url(from: "take\\1.mov", relativeTo: folder))
        #expect(url.lastPathComponent == "take\\1.mov")
    }

    @Test func takesOnlyASCIILettersForDrives() {
        #expect(ImportedMedia.windowsReference("é:/clip.mov") == nil)
        #expect(ImportedMedia.windowsReference("日:\\clip.mov") == nil)
    }

    @Test func readsFileURLsWhateverTheirCase() {
        #expect(ImportedMedia.url(from: "FILE://localhost/Volumes/A/clip.mov", relativeTo: nil)?.path == "/Volumes/A/clip.mov")
    }

    @Test func makesOneItemForAWindowsFileWhateverItsCase() {
        var media = ImportedMedia()
        let first = media.item(key: "a", reference: ImportedMedia.reference(from: "D:\\Media\\A.mov", relativeTo: nil),
                               name: "A.mov", kind: .video, metadata: MediaMetadata(duration: .zero))
        let second = media.item(key: "b", reference: ImportedMedia.reference(from: "d:\\media\\a.mov", relativeTo: nil),
                                name: "a.mov", kind: .video, metadata: MediaMetadata(duration: .zero))
        #expect(first.id == second.id)
        #expect(media.items.count == 1)
    }
}
