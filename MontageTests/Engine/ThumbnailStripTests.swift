import CoreGraphics
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct ThumbnailStripTests {
    @Test func picksTheCoarsestStepNoLongerThanATile() {
        #expect(ThumbnailStrip.interval(secondsPerTile: 0.01) == CMTime(value: 1, timescale: 10))
        #expect(ThumbnailStrip.interval(secondsPerTile: 1.5) == CMTime(value: 1, timescale: 1))
        #expect(ThumbnailStrip.interval(secondsPerTile: 7) == CMTime(value: 5, timescale: 1))
        #expect(ThumbnailStrip.interval(secondsPerTile: 10_000) == CMTime(value: 600, timescale: 1))
    }

    @Test func tilesTheClipWithFramesSnappedToTheStep() {
        // 10 seconds across 200 points, in tiles of 50: 2.5 seconds a tile,
        // snapped to steps of 2 seconds.
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 10, timescale: 1))
        let tiles = ThumbnailStrip.tiles(for: range, clipWidth: 200, tileWidth: 50)
        #expect(tiles.map(\.x) == [0, 50, 100, 150])
        #expect(tiles.map(\.time.seconds) == [0, 2, 6, 8])
    }

    @Test func leavesOutTilesOffScreen() {
        let range = CMTimeRange(start: .zero, duration: CMTime(value: 100, timescale: 1))
        let tiles = ThumbnailStrip.tiles(for: range, clipWidth: 1000, tileWidth: 50, visible: 400...520)
        #expect(tiles.map(\.x) == [350, 400, 450, 500])
    }

    @Test(.enabled(if: Samples.isAvailable))
    func makesFramesAsTallAsAsked() async throws {
        let item = MediaItem(name: "IMG_3311.mp4", kind: .video, location: .package(path: "Media/IMG_3311.mp4"),
                             metadata: MediaMetadata())
        let cache = ThumbnailCache()
        let url = Samples.url("IMG_3311.mp4")
        let first = try #require(await cache.frame(for: item, at: url, time: .zero, height: 60))
        #expect(first.height == 60)
        #expect(first.width > first.height)
        let later = try #require(await cache.frame(for: item, at: url, time: CMTime(value: 2, timescale: 1), height: 60))
        #expect(later !== first)
        // Kept: the file isn't looked at again.
        let again = await cache.frame(for: item, at: URL(fileURLWithPath: "/nonexistent.mp4"), time: .zero, height: 60)
        #expect(again === first)
    }
}
