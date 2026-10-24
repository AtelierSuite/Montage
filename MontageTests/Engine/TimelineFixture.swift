import CoreMedia
import Foundation
@testable import MontageEngine

/// Seconds.
private func s(_ seconds: Int64) -> CMTime {
    CMTime(value: seconds, timescale: 1)
}

private func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
    CMTimeRange(start: s(start), duration: s(duration))
}

/// A project of one ten-second video with sound, and a still image, with
/// clips of them laid out on a video track as asked.
struct TimelineFixture {
    let video = MediaItem(
        name: "video", kind: .video, location: .package(path: "Media/video"),
        metadata: MediaMetadata(duration: s(10), naturalSize: CGSize(width: 1920, height: 1080), audioChannelCount: 2)
    )
    let image = MediaItem(
        name: "image", kind: .image, location: .package(path: "Media/image"),
        metadata: MediaMetadata(naturalSize: CGSize(width: 100, height: 100))
    )
    var project: Project

    /// Clips of the video, each `(timeline start, source start, duration)`.
    init(_ clips: [(Int64, Int64, Int64)] = []) {
        let video = video
        project = Project(media: [video, image], tracks: [Track(kind: .video, clips: clips.map {
            Clip(mediaID: video.id, sourceRange: range($0.1, $0.2), timelineStart: s($0.0))
        })])
    }

    var clips: [Clip] { project.tracks[0].clips }
    func id(_ index: Int) -> Clip.ID { clips[index].id }
}
