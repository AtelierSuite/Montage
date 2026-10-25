import CoreMedia
import Foundation
import MontageEngine

/// The library's bins, clearing out unused media, and dropping media onto
/// the timeline.
extension ProjectEditor {
    /// Makes a bin with `media` filed in it, as one undo step, and returns
    /// its ID.
    @discardableResult
    func addBin(named name: String, filing media: Set<MediaItem.ID> = []) -> MediaBin.ID {
        var id = UUID()
        perform(String(localized: "Action.NewBin")) { project in
            id = project.addBin(named: name)
            project.moveMedia(media, toBin: id)
        }
        return id
    }

    func renameBin(_ id: MediaBin.ID, to name: String) {
        perform(String(localized: "Action.RenameBin")) { $0.renameBin(id, to: name) }
    }

    /// Takes a bin away, leaving what was in it in the library.
    func removeBin(_ id: MediaBin.ID) {
        perform(String(localized: "Action.DeleteBin")) { $0.removeBin(id) }
    }

    /// Files media in a bin, or in none with nil.
    func moveMedia(_ ids: Set<MediaItem.ID>, toBin binID: MediaBin.ID?) {
        perform(String(localized: "Action.MoveToBin")) { $0.moveMedia(ids, toBin: binID) }
    }

    /// Takes every item the timeline doesn't use out of the library, as one
    /// undo step. The files stay in the package, so undo can bring them back.
    func removeUnusedMedia() {
        perform(String(localized: "Action.RemoveUnusedMedia")) { $0.removeUnusedMedia() }
    }

    /// Selects the timeline's clips of the media, and takes the playhead to
    /// the first of them, which brings it into sight.
    func selectClips(usingMedia ids: Set<MediaItem.ID>) {
        let clips = project.clips(usingMedia: ids)
        guard let first = clips.first else { return }
        timeline.selectedClipIDs = Set(clips.map(\.id))
        playback.seek(to: first.timelineStart)
    }

    /// Puts media dropped on the timeline there: one after another from
    /// `time`, on `trackID` if it's of the media's kind and has room, else on
    /// another track that does, never covering what's there. For the
    /// timeline's drop target; returns the new clips' IDs.
    @discardableResult
    func insertMedia(_ ids: [MediaItem.ID], at time: CMTime, onTrack trackID: Track.ID? = nil) -> [Clip.ID] {
        var added: [Clip.ID] = []
        perform(String(localized: "Action.AddToTimeline")) { added = $0.insertClips(of: ids, at: time, onTrack: trackID) }
        return added
    }
}
