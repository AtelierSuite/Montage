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
    /// Clips moved by fractions of their picture fitted into the frame, as
    /// Resolve moves them, but placed as though their picture were of the
    /// frame's shape, until its media is probed.
    var picturePlacedClips: Set<Clip.ID> = []
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
