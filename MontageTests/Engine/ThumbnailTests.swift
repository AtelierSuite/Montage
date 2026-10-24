import CoreGraphics
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct ThumbnailTests {
    /// A 16:9 library cell, at twice its size.
    static let cellSize = CGSize(width: 220, height: 124)

    @Test(.enabled(if: Samples.isAvailable))
    func coversTheCellWithALandscapeVideo() async throws {
        let image = try #require(
            try await ThumbnailGenerator.thumbnail(of: Samples.url("IMG_3311.mp4"), kind: .video, filling: Self.cellSize)
        )
        #expect(image.width > image.height)
        #expect(image.width >= 218 && image.height >= 122)
        #expect(image.width <= 240 && image.height <= 140)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func turnsAPortraitVideoUpright() async throws {
        let image = try #require(
            try await ThumbnailGenerator.thumbnail(of: Samples.url("IMG_3312.mp4"), kind: .video, filling: Self.cellSize)
        )
        #expect(image.height > image.width)
        // Covering the cell's width means standing taller than it.
        #expect(image.width >= 218)
        #expect(image.width <= 240)
    }

    @Test(.enabled(if: Samples.isAvailable), arguments: ["IMG_2459.JPG", "IMG_2467.jpeg"])
    func coversTheCellWithAnUprightImage(_ name: String) async throws {
        let url = Samples.url(name)
        let probed = try await MediaProbe.probe(url)
        let image = try #require(try await ThumbnailGenerator.thumbnail(of: url, kind: .image, filling: Self.cellSize))
        let upright = probed.metadata.presentationSize
        #expect((image.width > image.height) == (upright.width > upright.height))
        #expect(image.width >= 218 && image.height >= 122)
        #expect(max(image.width, image.height) < Int(max(upright.width, upright.height)))
    }

    @Test func hasNoPictureForAudio() async throws {
        let image = try await ThumbnailGenerator.thumbnail(
            of: URL(fileURLWithPath: "/nonexistent.m4a"), kind: .audio, filling: Self.cellSize
        )
        #expect(image == nil)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func keepsAThumbnailOnceMade() async throws {
        let item = MediaItem(name: "IMG_3311.mp4", kind: .video, location: .package(path: "Media/IMG_3311.mp4"),
                             metadata: MediaMetadata())
        let cache = ThumbnailCache()
        let first = try #require(await cache.thumbnail(for: item, at: Samples.url("IMG_3311.mp4"), filling: Self.cellSize))
        // The file isn't looked at again: a path that doesn't exist still gives it.
        let second = await cache.thumbnail(for: item, at: URL(fileURLWithPath: "/nonexistent.mp4"), filling: Self.cellSize)
        #expect(second === first)
        await cache.removeThumbnails(for: item.id)
        let gone = await cache.thumbnail(for: item, at: URL(fileURLWithPath: "/nonexistent.mp4"), filling: Self.cellSize)
        #expect(gone == nil)
    }

    @Test func picksAFrameATenthInOrASecond() {
        #expect(ThumbnailGenerator.frameTime(forDuration: CMTime(value: 5, timescale: 1)).seconds == 0.5)
        #expect(ThumbnailGenerator.frameTime(forDuration: CMTime(value: 26, timescale: 1)).seconds == 1)
        #expect(ThumbnailGenerator.frameTime(forDuration: .invalid) == .zero)
    }

    @Test func fillsWithoutChangingShape() {
        let size = ThumbnailGenerator.fillingSize(for: CGSize(width: 1080, height: 1920), covering: Self.cellSize)
        #expect(size.width == 220)
        #expect(abs(size.height - 391.2) < 1)
    }
}
