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
        let kinds = derivedMediaKinds
        let missing = kinds.contains { kind in
            kind.media(neededIn: project).contains { store.existingURL(for: $0, kind) == nil }
        }
        guard missing else { return }
        guard derivedMediaTask == nil else {
            needsDerivedMedia = true
            return
        }
        let project = project, resolver = mediaResolver, derivedMedia = derivedMedia
        derivedMediaTask = Task { [weak self] in
            for kind in kinds {
                // Stereo copies first: they're small and quick, and proxies
                // take a while.
                guard await derivedMedia.makeAll(kind, neededIn: project, resolver: resolver) else { continue }
                self?.playbackController?.update(mediaResolver: self?.playbackResolver ?? resolver)
            }
            guard let self else { return }
            derivedMediaTask = nil
            if needsDerivedMedia {
                needsDerivedMedia = false
                makeDerivedMedia()
            }
        }
    }

    /// Stops making copies, such as when the project closes, rather than
    /// letting them run on. The next edit starts them again.
    func stopMakingDerivedMedia() {
        derivedMediaTask?.cancel()
        derivedMediaTask = nil
        needsDerivedMedia = false
    }
}
