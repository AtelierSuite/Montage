import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct PackageCacheTests {
    /// A package on disk, as a saved project leaves it.
    private func makePackage() throws -> URL {
        let url = URL.temporaryDirectory.appending(path: "PackageCacheTests \(UUID().uuidString).montage")
        let wrapper = try ProjectPackage.fileWrapper(for: Project(), existing: nil)
        try wrapper.write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(red: 1, green: 0.5, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    @Test func keepsThumbnailsAndWaveformsInThePackagesCache() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let cache = PackageCache(packageURL: package)
        let id = UUID()

        let poster = ThumbnailCache.Key(mediaID: id, size: CGSize(width: 32, height: 18))
        let frame = ThumbnailCache.Key(mediaID: id, height: 18, time: CMTime(value: 2, timescale: 1))
        await cache.store(try image(width: 32, height: 18), for: poster)
        await cache.store(try image(width: 24, height: 18), for: frame)
        let waveform = WaveformPeaks(peaksPerSecond: 100, peaks: [0, 0.5, 1])
        await cache.store(waveform, for: id)

        let folder = ProjectPackage.cacheDirectory(inPackageAt: package)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Thumbnails/\(id)/32x18.jpg").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Thumbnails/\(id)/h18/2000.jpg").path))
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "Waveforms/\(id).peaks").path))

        // A cache opened afresh, as when the project is opened again.
        let reopened = PackageCache(packageURL: package)
        #expect(await reopened.thumbnail(for: poster)?.width == 32)
        #expect(await reopened.thumbnail(for: frame)?.width == 24)
        #expect(await reopened.waveform(for: id)?.peaks.count == 3)

        // Kept when the project is saved again.
        let saved = try ProjectPackage.fileWrapper(
            for: Project(), existing: try FileWrapper(url: package), media: PackageMediaStore(packageURL: package)
        )
        #expect(saved.fileWrappers?["Cache"]?.fileWrappers?["Waveforms"] != nil)

        reopened.removeCache(for: id)
        #expect(await reopened.thumbnail(for: poster) == nil)
        #expect(await reopened.waveform(for: id) == nil)
    }

    @Test func keepsCopiesOfMediaInThePackagesCache() throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let cache = PackageCache(packageURL: package)
        let id = UUID()
        let folder = ProjectPackage.cacheDirectory(inPackageAt: package)
        let stereo = try #require(cache.url(for: id, .stereoAudio))
        #expect(stereo.standardizedFileURL == folder.appending(path: "Stereo/\(id).m4a").standardizedFileURL)
        #expect(cache.existingURL(for: id, .stereoAudio) == nil)
        let proxy = try #require(cache.url(for: id, .proxy))
        #expect(proxy.standardizedFileURL == folder.appending(path: "Proxies/\(id).mov").standardizedFileURL)

        try FileManager.default.createDirectory(at: stereo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("m4a".utf8).write(to: stereo)
        #expect(cache.existingURL(for: id, .stereoAudio) != nil)
        cache.removeCache(for: id)
        #expect(cache.existingURL(for: id, .stereoAudio) == nil)
        #expect(PackageCache().url(for: id, .stereoAudio) == nil)
    }

    @Test func keepsNothingBeforeThePackageIsSaved() async throws {
        let cache = PackageCache()
        let id = UUID()
        await cache.store(WaveformPeaks(peaksPerSecond: 100, peaks: [1]), for: id)
        #expect(await cache.waveform(for: id) == nil)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func makesWhatsMissingAgainOnceTheCacheIsDeleted() async throws {
        let package = try makePackage()
        defer { try? FileManager.default.removeItem(at: package) }
        let store = PackageCache(packageURL: package)
        let item = MediaItem(name: "IMG_3311.mp4", kind: .video, location: .package(path: "Media/IMG_3311.mp4"),
                             metadata: MediaMetadata())
        let url = Samples.url("IMG_3311.mp4")
        let size = CGSize(width: 64, height: 36)

        let waveform = try #require(await WaveformCache(store: store).waveform(for: item, at: url))
        #expect(await ThumbnailCache(store: store).thumbnail(for: item, at: url, filling: size) != nil)

        // Read back from the package, not the media: the file isn't there.
        let missing = URL(fileURLWithPath: "/nonexistent.mp4")
        #expect(await WaveformCache(store: store).waveform(for: item, at: missing)?.peaks.count == waveform.peaks.count)
        #expect(await ThumbnailCache(store: store).thumbnail(for: item, at: missing, filling: size) != nil)

        // Deleted, it's made again from the media, and written back.
        try FileManager.default.removeItem(at: ProjectPackage.cacheDirectory(inPackageAt: package))
        #expect(await WaveformCache(store: store).waveform(for: item, at: missing) == nil)
        #expect(await WaveformCache(store: store).waveform(for: item, at: url) != nil)
        #expect(await ThumbnailCache(store: store).thumbnail(for: item, at: url, filling: size) != nil)
        #expect(await store.waveform(for: item.id) != nil)
        #expect(await store.thumbnail(for: ThumbnailCache.Key(mediaID: item.id, size: size)) != nil)
    }
}
