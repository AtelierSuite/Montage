import Foundation
import MontageEngine

/// Making the copies of media that play in their place (see `DerivedMedia`),
/// in the background, into the package's cache.
extension ProjectEditor {
    /// Finds the media's files, and the copies made of them, for preview.
    var playbackResolver: MediaResolver {
        mediaResolver.findingDerivedMedia(in: derivedMedia.store)
    }

    /// The kinds of copy preview plays: stereo copies of mono media always,
    /// and proxies when they're turned on.
    private var derivedMediaKinds: [DerivedMedia] {
        usesProxies ? [.stereoAudio, .proxy] : [.stereoAudio]
    }

    /// Makes any copy the project now needs that hasn't been made, such as a
    /// stereo copy of mono media once a clip of it is panned, or a proxy of
    /// a 4K video, and builds the preview again to play each once it's there.
    func makeDerivedMedia() {
        guard let store = derivedMedia.store else { return }
        for kind in derivedMediaKinds {
            let missing = kind.media(neededIn: project).filter { item in
                let key = Self.settledKey(kind, item)
                guard !settledDerivedMedia.contains(key) else { return false }
                guard store.existingURL(for: item, kind) == nil else {
                    settledDerivedMedia.insert(key)
                    return false
                }
                return true
            }
            guard !missing.isEmpty else { continue }
            guard derivedMediaTasks[kind] == nil else {
                pendingDerivedMedia.insert(kind)
                continue
            }
            startMaking(kind, of: missing)
        }
    }

    private func startMaking(_ kind: DerivedMedia, of media: [MediaItem]) {
        let id = UUID()
        let resolver = mediaResolver, derivedMedia = derivedMedia
        let task = Task { [weak self] in
            for item in media {
                guard !Task.isCancelled else { return }
                guard let url = resolver.url(for: item) else { continue }
                let made = await derivedMedia.make(kind, for: item, from: url)
                guard !Task.isCancelled, let self else { return }
                // Made, or failed and not to be tried again from this file.
                settledDerivedMedia.insert(Self.settledKey(kind, item))
                // Each copy plays as soon as it's there.
                if made != nil { playbackController?.update(mediaResolver: playbackResolver) }
            }
            guard let self, derivedMediaTasks[kind]?.id == id else { return }
            derivedMediaTasks[kind] = nil
            if pendingDerivedMedia.remove(kind) != nil { makeDerivedMedia() }
        }
        derivedMediaTasks[kind] = (id, task)
    }

    private static func settledKey(_ kind: DerivedMedia, _ item: MediaItem) -> String {
        "\(kind.rawValue)/\(kind.fileName(for: item))"
    }

    /// Forgets what's known of an item's copies, so they're looked for again.
    func forgetDerivedMedia(for mediaID: MediaItem.ID) {
        settledDerivedMedia = settledDerivedMedia.filter { !$0.contains(mediaID.uuidString) }
    }

    /// Stops making copies, of one kind or every kind, such as when the
    /// project closes, rather than letting them run on. The next edit starts
    /// any that are still wanted again.
    func stopMakingDerivedMedia(_ kind: DerivedMedia? = nil) {
        for (key, running) in derivedMediaTasks where kind == nil || key == kind {
            running.task.cancel()
            derivedMediaTasks[key] = nil
            pendingDerivedMedia.remove(key)
        }
    }
}
