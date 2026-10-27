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
