import Foundation
@testable import MontageFormats
import Testing

/// Media paths as other editors write them, read as file URLs whose last
/// component names the file, so it can be looked for by name.
struct MediaPathTests {
    @Test(arguments: [
        ("D:\\NextCloud\\Rushes\\Camera\\MTC_2206.MP4", "/D:/NextCloud/Rushes/Camera/MTC_2206.MP4"),
        ("C:/Users/editor/Desktop/clip.mov", "/C:/Users/editor/Desktop/clip.mov"),
        ("\\\\server\\share\\Media\\clip.mov", "/server/share/Media/clip.mov"),
        ("file:///C:%5CUsers%5Ceditor%5Cclip.mov", "/C:/Users/editor/clip.mov"),
        ("file://localhost/C:/Media/clip.mov", "/C:/Media/clip.mov"),
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
}
