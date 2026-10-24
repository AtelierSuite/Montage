import CoreMedia

/// How many video layers can show at once.
///
/// Each video layer showing at a time needs a decoder of its own, and devices
/// only have so many: past the limit, AVFoundation fails the frames with
/// "Cannot Decode" (`AVError.decoderTemporarilyUnavailable`, -11839), and the
/// player gives up on the item. Apple documents no figure; it depends on the
/// device, the codec and the resolution, and other apps and the system share
/// the decoders. Reports put it at about 16 streams on an iPhone 6s, and
/// mobile editors cap themselves well under that. So the composition holds
/// back layers past a cautious limit, rather than fail to play at all.
public enum VideoLayerLimit {
    /// The most layers that show at once by default on this kind of device.
    /// On iPhone and iPad, low enough to leave decoders for the timeline's
    /// thumbnails and for the next clip at a cut; Macs decode in software
    /// when the hardware runs out, so their limit only guards against stalls.
    public static var standard: Int {
        #if os(macOS)
        16
        #else
        6
        #endif
    }

    /// The clips on the project's visible video tracks that would make more
    /// than `limit` layers show at once. Lower tracks win: a clip is held back
    /// where, anywhere along it, `limit` clips on the tracks under it already
    /// show.
    static func clipsOverLimit(in project: Project, limit: Int) -> Set<Clip.ID> {
        var placed: [CMTimeRange] = []
        var over = Set<Clip.ID>()
        for track in project.tracks where track.kind == .video && !track.isHidden {
            var placedOnTrack: [CMTimeRange] = []
            // Only video needs a decoder; stills, text and shapes are drawn.
            for clip in track.clips where clip.content.hasSourceTime && project.mediaItem(id: clip.mediaID)?.kind != .image {
                let range = clip.timelineRange
                if peakOverlap(of: placed, within: range) >= limit {
                    over.insert(clip.id)
                } else {
                    placedOnTrack.append(range)
                }
            }
            placed += placedOnTrack
        }
        return over
    }

    /// The most of `ranges` that overlap at any one time within `range`.
    private static func peakOverlap(of ranges: [CMTimeRange], within range: CMTimeRange) -> Int {
        let inside = ranges.map { $0.intersection(range) }.filter { $0.duration > .zero }
        // The count only rises where a range starts.
        let starts = inside.map(\.start)
        return starts.map { time in inside.count { $0.start <= time && time < $0.end } }.max() ?? 0
    }
}
