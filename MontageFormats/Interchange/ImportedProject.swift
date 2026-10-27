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
    /// Each media item's path as the file wrote it, where that isn't the
    /// path of its source, as with paths written on Windows.
    public var mediaSourcePaths: [MediaItem.ID: String] = [:]
}

/// The media an importer comes across, one item for each file however many
/// times it's used.
struct ImportedMedia {
    private(set) var items: [MediaItem] = []
    private(set) var sources: [MediaItem.ID: URL] = [:]
    private(set) var writtenPaths: [MediaItem.ID: String] = [:]
    private var idsByKey: [String: MediaItem.ID] = [:]
    private var takenPaths: Set<String> = []

    /// The item for a file, made the first time the file is seen. `key`
    /// tells files apart where there's no reference to.
    mutating func item(
        key: String, reference: MediaReference?, name: String, kind: MediaItem.Kind, metadata: MediaMetadata
    ) -> MediaItem {
        let url = reference?.url
        let key = url.map { reference!.ignoresCase ? $0.absoluteString.lowercased() : $0.absoluteString } ?? key
        if let id = idsByKey[key], let item = items.first(where: { $0.id == id }) { return item }
        let fileName = url.map { $0.lastPathComponent } ?? name
        let path = ProjectPackage.uniqueMediaPath(for: fileName.isEmpty ? name : fileName, avoiding: takenPaths)
        takenPaths.insert(path)
        let item = MediaItem(name: fileName.isEmpty ? name : fileName, kind: kind, location: .package(path: path), metadata: metadata)
        items.append(item)
        idsByKey[key] = item.id
        if let url { sources[item.id] = url }
        if let writtenPath = reference?.writtenPath { writtenPaths[item.id] = writtenPath }
        return item
    }

    /// A file reference as a URL. See `reference(from:relativeTo:)`.
    static func url(from reference: String?, relativeTo base: URL?) -> URL? {
        self.reference(from: reference, relativeTo: base)?.url
    }

    /// A file reference: a URL as written, or a path, which is taken from
    /// beside the file being read when it isn't absolute. Resolve and
    /// Premiere Pro on Windows write Windows paths, even in file URLs.
    static func reference(from text: String?, relativeTo base: URL?) -> MediaReference? {
        guard var reference = text?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
        var urlPath: String?
        for prefix in ["file://localhost/", "file:///", "file://"] where reference.lowercased().hasPrefix(prefix) {
            urlPath = String(reference.dropFirst(prefix.count))
            // Final Cut 7 wrote "file://localhost/Volumes/…".
            if prefix != "file://" { reference = "file:///" + urlPath! }
            break
        }
        let path = urlPath ?? reference
        if let windows = windowsReference(path.removingPercentEncoding ?? path) { return windows }

        if urlPath == nil, reference.contains("\\"), !reference.hasPrefix("/"), !reference.contains("://"), let base {
            // A Mac file's name can have a backslash in it, but where there's
            // no such file, it's a relative path written on Windows.
            let literal = base.appending(path: reference, directoryHint: .notDirectory).standardizedFileURL
            if FileManager.default.fileExists(atPath: literal.path) { return MediaReference(url: literal) }
            reference = reference.replacingOccurrences(of: "\\", with: "/")
        }
        if let url = URL(string: reference), url.scheme != nil {
            return MediaReference(url: url.isFileURL ? url.standardizedFileURL : url)
        }
        if let url = URL(string: reference, relativeTo: base), url.scheme != nil {
            return MediaReference(url: url.absoluteURL.standardizedFileURL)
        }
        if reference.hasPrefix("/") { return MediaReference(url: URL(fileURLWithPath: reference)) }
        return base.map { MediaReference(url: URL(fileURLWithPath: reference, relativeTo: $0).absoluteURL.standardizedFileURL) }
    }

    /// An absolute path written on Windows, with either kind of slash. A
    /// drive path, "D:\Media\a.mov", isn't on this Mac, but its URL,
    /// "/D:/Media/a.mov", names the file to look for. A network path,
    /// "\\server\share\a.mov", is looked for where the share is mounted on
    /// a Mac, "/Volumes/share/a.mov". Nil for anything else.
    static func windowsReference(_ path: String) -> MediaReference? {
        let start = Array(path.prefix(3))
        let isDrive = start.count == 3 && start[0].isASCII && start[0].isLetter && start[1] == ":"
            && (start[2] == "\\" || start[2] == "/")
        let isUNC = path.hasPrefix("\\\\")
        let components = path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).map(String.init)
        if isDrive {
            return MediaReference(url: URL(fileURLWithPath: "/" + components.joined(separator: "/")),
                                  writtenPath: components.joined(separator: "\\") + (components.count == 1 ? "\\" : ""),
                                  ignoresCase: true)
        }
        guard isUNC, components.count > 1 else { return nil }
        return MediaReference(url: URL(fileURLWithPath: "/Volumes/" + components.dropFirst().joined(separator: "/")),
                              writtenPath: "\\\\" + components.joined(separator: "\\"),
                              ignoresCase: true)
    }
}

/// Where a file reference points, and how to show it to the user.
struct MediaReference {
    var url: URL
    /// The path as written, where the URL's path isn't how the user knows it.
    var writtenPath: String?
    /// Whether the reference names the same file whatever its case, as
    /// Windows paths do.
    var ignoresCase = false
}
