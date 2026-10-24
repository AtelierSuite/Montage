import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// The frames a clip on the timeline shows along its length, at whatever
/// zoom the timeline is at.
///
/// The clip is cut into tiles of the thumbnails' width, side by side from its
/// left edge, and each tile shows the frame at the time of its left edge.
/// That time is snapped down to a grid of fixed steps (`intervals`), the
/// finest step no longer than a tile, so the same few frames come up again
/// as the timeline zooms a little or a clip is trimmed, and are found in the
/// cache rather than made again: each step is a zoom level.
public enum ThumbnailStrip {
    /// One thumbnail's place along a clip.
    public struct Tile: Equatable, Sendable {
        /// From the clip's left edge, in points.
        public var x: CGFloat
        /// The time in the media of the frame it shows.
        public var time: CMTime
    }

    /// The steps the frames' times are snapped to, finest first.
    public static let intervals: [CMTime] = [
        CMTime(value: 1, timescale: 10), CMTime(value: 1, timescale: 4), CMTime(value: 1, timescale: 2),
        CMTime(value: 1, timescale: 1), CMTime(value: 2, timescale: 1), CMTime(value: 5, timescale: 1),
        CMTime(value: 10, timescale: 1), CMTime(value: 30, timescale: 1), CMTime(value: 60, timescale: 1),
        CMTime(value: 300, timescale: 1), CMTime(value: 600, timescale: 1),
    ]

    /// The step for tiles that each cover `secondsPerTile` of media: the
    /// coarsest that's no longer than a tile, so neighbouring tiles never
    /// show the same frame.
    public static func interval(secondsPerTile: Double) -> CMTime {
        intervals.last { $0.seconds <= secondsPerTile } ?? intervals[0]
    }

    /// The tiles along a clip that shows `sourceRange` of its media across
    /// `clipWidth` points, each `tileWidth` wide. Only tiles that overlap
    /// `visible` (in the clip's own points) are given, so a long clip
    /// scrolled mostly off screen doesn't ask for frames nobody sees.
    public static func tiles(
        for sourceRange: CMTimeRange, clipWidth: CGFloat, tileWidth: CGFloat,
        visible: ClosedRange<CGFloat>? = nil
    ) -> [Tile] {
        guard clipWidth > 0, tileWidth > 0, sourceRange.duration.isNumeric, sourceRange.duration > .zero else {
            return []
        }
        let secondsPerPoint = sourceRange.duration.seconds / clipWidth
        let step = interval(secondsPerTile: secondsPerPoint * tileWidth).seconds
        let count = Int((clipWidth / tileWidth).rounded(.up))
        return (0..<count).compactMap { index in
            let x = CGFloat(index) * tileWidth
            if let visible, x + tileWidth < visible.lowerBound || x > visible.upperBound { return nil }
            let seconds = sourceRange.start.seconds + x * secondsPerPoint
            let snapped = (seconds / step).rounded(.down) * step
            return Tile(x: x, time: CMTime(seconds: snapped, preferredTimescale: 600))
        }
    }
}

extension ThumbnailGenerator {
    /// The video's frame nearest `time`, upright, `height` pixels tall. A
    /// still image is the same at every time.
    public static func frame(of url: URL, kind: MediaItem.Kind, at time: CMTime, height: CGFloat) async throws -> CGImage? {
        switch kind {
        case .video:
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            // As tall as asked; the width follows from the picture's shape.
            generator.maximumSize = CGSize(width: height * 4, height: height)
            // A tile only needs a frame near its time, and the nearest
            // keyframe comes quickest.
            let tolerance = CMTime(value: 1, timescale: 4)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            return try await generator.image(at: time).image
        case .image:
            return try await thumbnail(of: url, kind: .image, filling: CGSize(width: height, height: height))
        case .audio:
            return nil
        }
    }
}

extension ThumbnailCache {
    /// A frame for a tile of the timeline's strip, `height` pixels tall,
    /// made if it hasn't been. Still images give the same picture for every
    /// tile; audio gives none.
    public func frame(for item: MediaItem, at url: URL, time: CMTime, height: CGFloat) async -> CGImage? {
        guard item.kind != .audio else { return nil }
        let kind = item.kind
        let key = Key(mediaID: item.id, height: height, time: kind == .image ? .zero : time)
        return await image(for: key) { key in
            try? await ThumbnailGenerator.frame(of: url, kind: kind, at: key.time ?? .zero, height: key.size.height)
        }
    }
}
