import CoreMedia
import Foundation

/// Changes to the project's media and the clips made from it.
extension Project {
    /// How long a still image's clip lasts when it's added to the timeline.
    public static let defaultImageDuration = CMTime(value: 5, timescale: 1)

    /// The kind of track a media item's clips go on.
    public static func trackKind(for kind: MediaItem.Kind) -> Track.Kind {
        kind == .audio ? .audio : .video
    }

    /// Adds media to the end of the library.
    public mutating func addMedia(_ items: [MediaItem]) {
        media.append(contentsOf: items)
    }

    /// Takes media out of the library, and every clip made from it off the
    /// timeline. Tracks left empty stay.
    public mutating func removeMedia(_ ids: Set<MediaItem.ID>) {
        media.removeAll { ids.contains($0.id) }
        for index in tracks.indices {
            for clip in tracks[index].clips where ids.contains(clip.mediaID) {
                tracks[index].remove(clip.id)
            }
        }
    }

    /// Puts the whole of a media item at the end of the first track of its
    /// kind: video and images on the first video track, audio on the first
    /// audio track. The track is made if there isn't one. Returns the new
    /// clip's ID, or nil if the item isn't in the project.
    @discardableResult
    public mutating func appendClip(of mediaID: MediaItem.ID) -> Clip.ID? {
        guard let item = mediaItem(id: mediaID) else { return nil }
        let duration = item.kind == .image ? Self.defaultImageDuration : item.metadata.duration
        guard duration.isNumeric, duration > .zero else { return nil }
        let clip = Clip(mediaID: mediaID, sourceRange: CMTimeRange(start: .zero, duration: duration))
        let index = firstTrackIndex(of: Self.trackKind(for: item.kind))
        tracks[index].append(clip)
        return clip.id
    }

    /// The first track of a kind, made if there's none. Video tracks come
    /// before audio tracks, so a new video track goes after the last video
    /// track and a new audio track at the end.
    private mutating func firstTrackIndex(of kind: Track.Kind) -> Int {
        if let index = tracks.firstIndex(where: { $0.kind == kind }) { return index }
        let index = kind == .video ? (tracks.firstIndex { $0.kind == .audio } ?? tracks.endIndex) : tracks.endIndex
        tracks.insert(Track(kind: kind), at: index)
        return index
    }
}
