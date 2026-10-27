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
    /// Reads the file again once its media has been found, for formats
    /// that need something only the media says, such as an EDL's frame
    /// rate or the timecode its files start at. `ProjectInterchange.gatherMedia`
    /// calls it last.
    var conformToMedia: (@Sendable (ImportedProject) -> ImportedProject)?
    /// Clips moved by fractions of their picture fitted into the frame, as
    /// Resolve moves them, but placed as though their picture were of the
    /// frame's shape, until its media is probed.
    var picturePlacedClips: Set<Clip.ID> = []
    /// Media whose clips' times may be by its timecode, as the file didn't
    /// say where the media's own time starts.
    var untimedMedia: Set<MediaItem.ID> = []
}

extension ImportedProject {
    /// Moves the clips placed as though their picture were of the frame's
    /// shape by fractions of their picture as probed: as far as it reaches
    /// across and down once fitted into the frame. A picture whose media
    /// wasn't found stays taken to be the frame's shape.
    mutating func placeByProbedPictures() {
        let frame = project.settings.renderSize
        guard !picturePlacedClips.isEmpty, frame.width > 0, frame.height > 0 else { return }
        for track in project.tracks.indices {
            for clip in project.tracks[track].clips where picturePlacedClips.contains(clip.id) {
                guard let picture = project.media.first(where: { $0.id == clip.mediaID })?.metadata.presentationSize,
                      picture.width > 0, picture.height > 0 else { continue }
                let fit = min(frame.width / picture.width, frame.height / picture.height)
                let reach = CGSize(width: picture.width * fit / frame.width, height: picture.height * fit / frame.height)
                func placed(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: 0.5 + (point.x - 0.5) * reach.width, y: 0.5 + (point.y - 0.5) * reach.height)
                }
                let position = clip.transform.position
                project.tracks[track].update(clip.id) { clip in
                    clip.transform.position = Animatable(placed(position.value), keyframes: position.keyframes.map {
                        Keyframe(time: $0.time, value: placed($0.value), interpolation: $0.interpolation)
                    })
                }
            }
        }
        picturePlacedClips = []
    }

    /// Takes the start of each media's timecode, from `starts`, off its
    /// clips' times, where they run past the end of the media as they are
    /// but fit it counted from its timecode: they were given by timecode.
    mutating func startClipsAtTimecode(_ starts: [MediaItem.ID: CMTime]) {
        for (id, start) in starts where start > .zero {
            guard let duration = project.media.first(where: { $0.id == id })?.metadata.duration, duration > .zero else { continue }
            let clips = project.tracks.flatMap(\.clips).filter { $0.mediaID == id }
            guard clips.contains(where: { $0.sourceRange.end > duration }),
                  clips.allSatisfy({ CMTimeRange(start: start, duration: duration).containsTimeRange($0.sourceRange) }) else { continue }
            for track in project.tracks.indices {
                for clip in project.tracks[track].clips where clip.mediaID == id {
                    project.tracks[track].update(clip.id) { $0.sourceRange.start = $0.sourceRange.start - start }
                }
            }
        }
        untimedMedia = []
    }
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
    /// tells files apart where there's no reference to. The item is named
    /// after the referenced file, or with `keepsName`, as when a package
    /// stores the file under a name of its own, `name` all the same.
    /// `sourceTimecode` is how its clips' source points count, where they're
    /// in its timecode.
    mutating func item(
        key: String, reference: MediaReference?, name: String, keepsName: Bool = false, kind: MediaItem.Kind,
        metadata: MediaMetadata, sourceTimecode: MediaItem.SourceTimecode? = nil
    ) -> MediaItem {
        let url = reference?.url
        let key = url.map { reference!.ignoresCase ? $0.absoluteString.lowercased() : $0.absoluteString } ?? key
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
        if let writtenPath = reference?.writtenPath { writtenPaths[item.id] = writtenPath }
        return item
    }

    /// The item for a file at a URL. See `item(key:reference:…)`.
    mutating func item(
        key: String, url: URL?, name: String, keepsName: Bool = false, kind: MediaItem.Kind, metadata: MediaMetadata,
        sourceTimecode: MediaItem.SourceTimecode? = nil
    ) -> MediaItem {
        item(
            key: key, reference: url.map { MediaReference(url: $0) }, name: name, keepsName: keepsName, kind: kind,
            metadata: metadata, sourceTimecode: sourceTimecode
        )
    }

    /// Puts back an item made earlier, changed: one first taken for a sound
    /// file that turns out to have a picture.
    mutating func update(_ item: MediaItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = item
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
