@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// Keeps copies of media in a folder of its own.
private struct FolderStore: DerivedMediaStore {
    let folder: URL

    func url(for mediaID: MediaItem.ID, _ kind: DerivedMedia) -> URL? {
        folder.appending(path: "\(kind.rawValue)-\(mediaID.uuidString).\(kind == .proxy ? "mov" : "m4a")")
    }
}

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func video(width: Double, height: Double, kind: MediaItem.Kind = .video) -> MediaItem {
    MediaItem(
        name: "IMG_3311.mp4", kind: kind, location: .package(path: "IMG_3311.mp4"),
        metadata: MediaMetadata(
            duration: CMTime(value: 11250, timescale: 1000), naturalSize: CGSize(width: width, height: height),
            audioChannelCount: 2, audioSampleRate: 48_000
        )
    )
}

struct ProxyPolicyTests {
    @Test func onlyVideoLargerThanHDGetsAProxy() {
        #expect(DerivedMedia.proxy.applies(to: video(width: 3840, height: 2160)))
        #expect(DerivedMedia.proxy.applies(to: video(width: 2160, height: 3840)))
        #expect(DerivedMedia.proxy.applies(to: video(width: 2048, height: 1080)))
        #expect(!DerivedMedia.proxy.applies(to: video(width: 1920, height: 1080)))
        #expect(!DerivedMedia.proxy.applies(to: video(width: 1080, height: 1920)))
        #expect(!DerivedMedia.proxy.applies(to: video(width: 4000, height: 3000, kind: .image)))
    }

    @Test func onlyClipsOnVideoTracksNeedProxies() {
        let large = video(width: 3840, height: 2160)
        let clip = Clip(mediaID: large.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)))
        let onVideo = Project(media: [large], tracks: [Track(kind: .video, clips: [clip])])
        #expect(DerivedMedia.proxy.media(neededIn: onVideo).map(\.id) == [large.id])
        let onAudio = Project(media: [large], tracks: [Track(kind: .audio, clips: [clip])])
        #expect(DerivedMedia.proxy.media(neededIn: onAudio).isEmpty)
        var hidden = onVideo
        hidden.tracks[0].isHidden = true
        #expect(DerivedMedia.proxy.media(neededIn: hidden).isEmpty)
        #expect(DerivedMedia.proxy.media(neededIn: Project(media: [large])).isEmpty)
    }
}

@Suite(.enabled(if: Samples.isAvailable, "Needs the sample media"))
struct ProxyTests {
    private let folder: URL
    private let store: FolderStore
    /// The landscape sample, said to be 4K so it gets a proxy.
    private let item = video(width: 3840, height: 2160)
    private let resolver = MediaResolver { item in
        guard case .package(let path) = item.location else { return nil }
        return Samples.url(path)
    }

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "ProxyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        store = FolderStore(folder: folder)
    }

    private var project: Project {
        let clip = Clip(mediaID: item.id, sourceRange: CMTimeRange(start: seconds(1), duration: seconds(2)))
        return Project(media: [item], tracks: [Track(kind: .video, clips: [clip])])
    }

    /// The files the composition's tracks of a type play from.
    private func sources(of built: BuiltComposition, _ type: AVMediaType) -> [URL?] {
        built.composition.tracks(withMediaType: type).compactMap { $0 as? AVCompositionTrack }.flatMap { track in
            track.segments.filter { !$0.isEmpty }.map(\.sourceURL)
        }
    }

    @Test func makesASmallerProxyTimedAsTheOriginal() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DerivedMediaCache(store: store)
        #expect(await cache.makeAll(.proxy, neededIn: project, resolver: resolver))
        let proxy = try #require(store.existingURL(for: item.id, .proxy))

        let original = try #require(try await AVURLAsset(url: Samples.url("IMG_3311.mp4")).loadTracks(withMediaType: .video).first)
        let track = try #require(try await AVURLAsset(url: proxy).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width <= 960 && size.height <= 540)
        let (proxyRange, originalRange) = (try await track.load(.timeRange), try await original.load(.timeRange))
        #expect(abs(proxyRange.start.seconds - originalRange.start.seconds) < 0.05)
        #expect(abs(proxyRange.duration.seconds - originalRange.duration.seconds) < 0.05)
    }

    @Test func previewPlaysTheProxyAndExportTheOriginal() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DerivedMediaCache(store: store)
        #expect(await cache.makeAll(.proxy, neededIn: project, resolver: resolver))
        let proxy = store.url(for: item.id, .proxy)
        let original = Samples.url("IMG_3311.mp4")
        let finding = resolver.findingDerivedMedia(in: store)

        var preview = CompositionBuilder(project: project, mediaResolver: finding)
        preview.usesProxies = true
        let previewed = try await preview.build()
        #expect(sources(of: previewed, .video) == [proxy])
        // Its sound is still the original's.
        #expect(sources(of: previewed, .audio) == [original])
        #expect(previewed.duration == seconds(2))

        let exported = try await CompositionBuilder(project: project, mediaResolver: finding).build()
        #expect(sources(of: exported, .video) == [original])
    }

    @Test func withoutAProxyTheOriginalPlays() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var builder = CompositionBuilder(project: project, mediaResolver: resolver.findingDerivedMedia(in: store))
        builder.usesProxies = true
        let built = try await builder.build()
        #expect(sources(of: built, .video) == [Samples.url("IMG_3311.mp4")])
    }

    @MainActor
    @Test func turningProxiesOnRebuildsThePreview() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let cache = DerivedMediaCache(store: store)
        #expect(await cache.makeAll(.proxy, neededIn: project, resolver: resolver))
        let controller = PlaybackController(
            project: project, mediaResolver: resolver.findingDerivedMedia(in: store), rebuildDelay: .milliseconds(10)
        )
        defer { controller.invalidate() }
        func waitUntil(_ condition: () -> Bool) async throws {
            for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(25)) }
            #expect(condition())
        }
        try await waitUntil { controller.composition != nil }
        #expect(controller.composition.map { sources(of: $0, .video) } == [Samples.url("IMG_3311.mp4")])
        controller.usesProxies = true
        let proxy = store.url(for: item.id, .proxy)
        try await waitUntil { controller.composition.map { sources(of: $0, .video) } == [proxy] }
    }
}
