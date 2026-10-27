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
    /// Reads the file again once its media has been found, for formats
    /// that need something only the media says, such as an EDL's frame
    /// rate or the timecode its files start at. `ProjectInterchange.gatherMedia`
    /// calls it last.
    var conformToMedia: (@Sendable (ImportedProject) -> ImportedProject)?
}

/// The media an importer comes across, one item for each file however many
/// times it's used.
struct ImportedMedia {
    private(set) var items: [MediaItem] = []
    private(set) var sources: [MediaItem.ID: URL] = [:]
    private var idsByKey: [String: MediaItem.ID] = [:]
    private var takenPaths: Set<String> = []

    /// The item for a file, made the first time the file is seen. `key`
    /// tells files apart where there's no URL to. The item is named after
    /// the URL's file, or with `keepsName`, as when a package stores the
    /// file under a name of its own, `name` all the same. `sourceTimecode`
    /// is how its clips' source points count, where they're in its timecode.
    mutating func item(
        key: String, url: URL?, name: String, keepsName: Bool = false, kind: MediaItem.Kind, metadata: MediaMetadata,
        sourceTimecode: MediaItem.SourceTimecode? = nil
    ) -> MediaItem {
        let key = url?.absoluteString ?? key
        if let id = idsByKey[key], let item = items.first(where: { $0.id == id }) { return item }
        let fileName = keepsName ? name : url.map { $0.lastPathComponent } ?? name
        let path = ProjectPackage.uniqueMediaPath(for: fileName.isEmpty ? name : fileName, avoiding: takenPaths)
        takenPaths.insert(path)
        let item = MediaItem(
            name: fileName.isEmpty ? name : fileName, kind: kind, location: .package(path: path), metadata: metadata,
            sourceTimecode: sourceTimecode
        )
        items.append(item)
        idsByKey[key] = item.id
        if let url { sources[item.id] = url }
        return item
    }

    /// Puts back an item made earlier, changed: one first taken for a sound
    /// file that turns out to have a picture.
    mutating func update(_ item: MediaItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
    }

    /// A file reference as a URL: a URL as written, or a path, which is
    /// taken from beside the file being read when it isn't absolute.
    static func url(from reference: String?, relativeTo base: URL?) -> URL? {
        guard let reference = reference?.trimmingCharacters(in: .whitespacesAndNewlines), !reference.isEmpty else { return nil }
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
}
