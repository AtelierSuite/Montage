import CoreMedia
import Foundation
import MontageEngine

/// A project read from another editor's file, with what couldn't come
/// across exactly.
///
/// Its media items stand for the files the other editor used. Each has a
/// place reserved in the project's package, but no file there yet: until
/// `ProjectInterchange.gatherMedia` finds and copies the files in, the items
/// don't resolve, and are shown as missing so they can be relinked.
public struct ImportedProject: Sendable {
    public var project: Project
    public var report: ImportReport
    /// The timeline's name in the other editor.
    public var name: String?
    /// Where each media item's file was, as the file said: where to look
    /// for it, or what to tell the user when it isn't there.
    public var mediaSources: [MediaItem.ID: URL]
}

/// The media an importer comes across, one item for each file however many
/// times it's used.
struct ImportedMedia {
    private(set) var items: [MediaItem] = []
    private(set) var sources: [MediaItem.ID: URL] = [:]
    private var idsByKey: [String: MediaItem.ID] = [:]
    private var takenPaths: Set<String> = []

    /// The item for a file, made the first time the file is seen. `key`
    /// tells files apart where there's no URL to.
    mutating func item(
        key: String, url: URL?, name: String, kind: MediaItem.Kind, metadata: MediaMetadata
    ) -> MediaItem {
        let key = url?.absoluteString ?? key
        if let id = idsByKey[key], let item = items.first(where: { $0.id == id }) { return item }
        let fileName = url.map { $0.lastPathComponent } ?? name
        let path = ProjectPackage.uniqueMediaPath(for: fileName.isEmpty ? name : fileName, avoiding: takenPaths)
        takenPaths.insert(path)
        let item = MediaItem(name: fileName.isEmpty ? name : fileName, kind: kind, location: .package(path: path), metadata: metadata)
        items.append(item)
        idsByKey[key] = item.id
        if let url { sources[item.id] = url }
        return item
    }

    /// A file reference as a URL: a URL as written, or a path, which is
    /// taken from beside the file being read when it isn't absolute.
    static func url(from reference: String?, relativeTo base: URL?) -> URL? {
        guard var reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
        if let path = windowsPath(reference) {
            // Not on this Mac, but its last component names the file to look for.
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            reference = path
        }
        // Final Cut 7 wrote "file://localhost/Volumes/…".
        let normalized = reference.replacingOccurrences(of: "file://localhost/", with: "file:///")
        if let url = URL(string: normalized), url.scheme != nil {
            return url.isFileURL ? url.standardizedFileURL : url
        }
        if let url = URL(string: normalized, relativeTo: base), url.scheme != nil {
            return url.absoluteURL.standardizedFileURL
        }
        if normalized.hasPrefix("/") { return URL(fileURLWithPath: normalized) }
        return base.map { URL(fileURLWithPath: normalized, relativeTo: $0).absoluteURL.standardizedFileURL }
    }

    /// A path written on Windows, with forward slashes: "D:\Media\a.mov" as
    /// "/D:/Media/a.mov", "\\server\share\a.mov" as "/server/share/a.mov",
    /// and "Media\a.mov" as "Media/a.mov". Nil for anything else. Resolve and
    /// Premiere Pro on Windows write paths like these, even in file URLs.
    static func windowsPath(_ reference: String) -> String? {
        var path = reference
        for prefix in ["file://localhost/", "file:///", "file://"] where path.lowercased().hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
            path = path.removingPercentEncoding ?? path
            break
        }
        let isDrive = path.count >= 3 && path.first!.isLetter && path.dropFirst().first == ":"
            && "\\/".contains(path[path.index(path.startIndex, offsetBy: 2)])
        let isUNC = path.hasPrefix("\\\\")
        guard isDrive || isUNC || (path.contains("\\") && !path.contains("/")) else { return nil }
        let slashed = path.replacingOccurrences(of: "\\", with: "/")
        if isUNC { return "/" + slashed.drop { $0 == "/" } }
        return isDrive ? "/" + slashed : slashed
    }
}
