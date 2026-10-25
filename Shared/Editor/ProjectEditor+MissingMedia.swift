import CoreMedia
import Foundation
import MontageEngine

/// Finding the media whose files have gone, and pointing it at files again.
extension ProjectEditor {
    /// Looks for every media item's file, noting which can't be found, and
    /// puts in fresh bookmarks for any that turned out stale.
    ///
    /// The look is made off the main actor, as resolving bookmarks and
    /// reaching files on other volumes can take a while, and a project's
    /// worth of them longer. A look started while another's under way
    /// replaces it. Returns the look, for whoever needs `missingMediaIDs` to
    /// be up to date to wait for it.
    @discardableResult
    func checkMedia() -> Task<Void, Never> {
        mediaCheck?.cancel()
        let resolver = mediaResolver, media = project.media
        let check = Task { [weak self] in
            let missing = await Self.missingMedia(in: media, resolver: resolver)
            guard !Task.isCancelled, let self else { return }
            if missing != missingMediaIDs { missingMediaIDs = missing }

            let fresh = takeRefreshedBookmarks()
            if !fresh.isEmpty {
                amend { $0.replaceBookmarks(fresh) }
            }
        }
        mediaCheck = check
        return check
    }

    /// Waits for the look under way, and any started meanwhile in its place,
    /// such as for the fresh bookmarks it found.
    func mediaChecked() async {
        while let check = mediaCheck {
            await check.value
            if mediaCheck == check { return }
        }
    }

    @concurrent
    private nonisolated static func missingMedia(in media: [MediaItem], resolver: MediaResolver) async -> Set<MediaItem.ID> {
        Set(media.filter { item in
            guard let url = resolver.url(for: item) else { return true }
            return (try? url.checkResourceIsReachable()) != true
        }.map(\.id))
    }

    /// The media whose files can't be found, in library order.
    var missingMedia: [MediaItem] {
        project.media.filter { missingMediaIDs.contains($0.id) }
    }

    /// Points media at other files, as one undo step: the relink the user
    /// confirmed. Each item keeps its name, bin and clips, and takes the new
    /// file's location and what it's like. Whatever was made from the old
    /// files, if anything, is thrown away first, as it isn't of the new ones.
    /// Clips whose source points are in a file's timecode, as an edit
    /// decision list gives them, are moved onto it by `timecodeStarts`, the
    /// timecode each new file starts at.
    func relinkMedia(
        _ relinks: [MediaItem.ID: (location: MediaLocation, metadata: MediaMetadata)],
        timecodeStarts: [MediaItem.ID: CMTime] = [:]
    ) async {
        guard !relinks.isEmpty else { return }
        for id in relinks.keys {
            cacheStore?.removeCache(for: id)
            await thumbnails.removeThumbnails(for: id)
            await waveforms.removeWaveform(for: id)
            await derivedMedia.forgetFailures(for: id)
            forgetDerivedMedia(for: id)
        }
        perform(String(localized: "Action.RelinkMedia")) { project in
            for index in project.media.indices {
                guard let relink = relinks[project.media[index].id] else { continue }
                project.media[index].location = relink.location
                project.media[index].metadata = relink.metadata
                if let start = timecodeStarts[project.media[index].id] {
                    project.alignSourceRanges(of: project.media[index].id, toTimecodeStart: start, duration: relink.metadata.duration)
                }
            }
        }
        // Done once the relinked media is no longer missing.
        await mediaChecked()
    }
}
