import Foundation
import MontageEngine

/// Finding the media whose files have gone, and pointing it at files again.
extension ProjectEditor {
    /// Looks for every media item's file, noting which can't be found, and
    /// puts in fresh bookmarks for any that turned out stale.
    func checkMedia() {
        let resolver = mediaResolver
        let missing = Set(project.media.filter { item in
            guard let url = resolver.url(for: item) else { return true }
            return (try? url.checkResourceIsReachable()) != true
        }.map(\.id))
        if missing != missingMediaIDs { missingMediaIDs = missing }

        let fresh = takeRefreshedBookmarks()
        if !fresh.isEmpty {
            amend { $0.replaceBookmarks(fresh) }
        }
    }

    /// The media whose files can't be found, in library order.
    var missingMedia: [MediaItem] {
        project.media.filter { missingMediaIDs.contains($0.id) }
    }

    /// Points media at other files, as one undo step: the relink the user
    /// confirmed. Each item keeps its name, bin and clips, and takes the new
    /// file's location and what it's like. Whatever was made from the old
    /// files, if anything, is thrown away first, as it isn't of the new ones.
    func relinkMedia(_ relinks: [MediaItem.ID: (location: MediaLocation, metadata: MediaMetadata)]) async {
        guard !relinks.isEmpty else { return }
        for id in relinks.keys {
            cacheStore?.removeCache(for: id)
            await thumbnails.removeThumbnails(for: id)
            await waveforms.removeWaveform(for: id)
            await derivedMedia.forgetFailures(for: id)
        }
        perform(String(localized: "Action.RelinkMedia")) { project in
            for index in project.media.indices {
                guard let relink = relinks[project.media[index].id] else { continue }
                project.media[index].location = relink.location
                project.media[index].metadata = relink.metadata
            }
        }
    }
}
