import Foundation
import MontageEngine

/// Making the copies of media that play in their place (see `DerivedMedia`),
/// in the background, into the package's cache.
extension ProjectEditor {
    /// Finds the media's files, and the copies made of them, for preview.
    var playbackResolver: MediaResolver {
        mediaResolver.findingDerivedMedia(in: derivedMedia.store)
    }

    /// Makes any copy the project now needs that hasn't been made, such as a
    /// stereo copy of mono media once a clip of it is panned, and builds the
    /// preview again to play it once it's there.
    func makeDerivedMedia() {
        guard let store = derivedMedia.store else { return }
        let missing = DerivedMedia.stereoAudio.media(neededIn: project).contains { store.existingURL(for: $0.id, .stereoAudio) == nil }
        guard missing else { return }
        guard derivedMediaTask == nil else {
            needsDerivedMedia = true
            return
        }
        let project = project, resolver = mediaResolver, derivedMedia = derivedMedia
        derivedMediaTask = Task { [weak self] in
            let madeAny = await derivedMedia.makeAll(.stereoAudio, neededIn: project, resolver: resolver)
            guard let self else { return }
            derivedMediaTask = nil
            if madeAny { playbackController?.update(mediaResolver: playbackResolver) }
            if needsDerivedMedia {
                needsDerivedMedia = false
                makeDerivedMedia()
            }
        }
    }
}
