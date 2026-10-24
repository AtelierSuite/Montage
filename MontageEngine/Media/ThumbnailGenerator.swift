import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Makes small still pictures of media, for the library to show. Audio has
/// no picture, so it gets none.
public enum ThumbnailGenerator {
    /// A picture of the media, upright, scaled so it covers `size` (in
    /// pixels) while keeping its shape, to be cropped to it. Nil for audio.
    public static func thumbnail(of url: URL, kind: MediaItem.Kind, filling size: CGSize) async throws -> CGImage? {
        switch kind {
        case .video: try await videoThumbnail(of: url, filling: size)
        case .image: try imageThumbnail(of: url, filling: size)
        case .audio: nil
        }
    }

    /// The size that covers `target` with something shaped like `source`,
    /// as small as it can be.
    static func fillingSize(for source: CGSize, covering target: CGSize) -> CGSize {
        guard source.width > 0, source.height > 0 else { return target }
        let scale = max(target.width / source.width, target.height / source.height)
        return CGSize(width: (source.width * scale).rounded(.up), height: (source.height * scale).rounded(.up))
    }

    // MARK: - Video

    /// A frame a tenth of the way in, or a second in for anything longer than
    /// ten seconds, past the fade-in or black frame many videos open with.
    static func frameTime(forDuration duration: CMTime) -> CMTime {
        guard duration.isNumeric, duration > .zero else { return .zero }
        return CMTimeMinimum(CMTimeMultiplyByFloat64(duration, multiplier: 0.1), CMTime(value: 1, timescale: 1))
    }

    private static func videoThumbnail(of url: URL, filling size: CGSize) async throws -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (naturalSize, transform) = try await track.load(.naturalSize, .preferredTransform)
        let upright = naturalSize.applying(transform)
        let duration = try await asset.load(.duration)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = fillingSize(
            for: CGSize(width: abs(upright.width), height: abs(upright.height)), covering: size
        )
        // Any nearby frame will do, and the nearest keyframe comes quickest.
        let tolerance = CMTime(value: 1, timescale: 2)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        return try await generator.image(at: frameTime(forDuration: duration)).image
    }

    // MARK: - Images

    private static func imageThumbnail(of url: URL, filling size: CGSize) throws -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let rotation = MediaProbe.rotation(for: orientation)
        let upright = rotation % 180 == 0
            ? CGSize(width: width, height: height) : CGSize(width: height, height: width)
        let filling = fillingSize(for: upright, covering: size)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(filling.width, filling.height),
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// Keeps thumbnails once made, so scrolling back to media doesn't make them
/// again, and asks for each only once however many views want it at a time.
///
/// Thumbnails are kept in memory. A store kept on disk, such as in the
/// project package's cache, can stand behind it through `ThumbnailStore`.
public actor ThumbnailCache {
    public struct Key: Hashable, Sendable {
        public var mediaID: MediaItem.ID
        /// The size, in pixels, that the thumbnail covers.
        public var width: Int
        public var height: Int

        public init(mediaID: MediaItem.ID, size: CGSize) {
            self.mediaID = mediaID
            width = Int(size.width.rounded(.up))
            height = Int(size.height.rounded(.up))
        }

        public var size: CGSize { CGSize(width: width, height: height) }
    }

    private let store: (any ThumbnailStore)?
    private let capacity: Int
    private var images: [Key: CGImage] = [:]
    /// Keys from least to most recently used, to know which to let go.
    private var recency: [Key] = []
    private var inFlight: [Key: Task<CGImage?, Never>] = [:]

    public init(store: (any ThumbnailStore)? = nil, capacity: Int = 300) {
        self.store = store
        self.capacity = max(capacity, 1)
    }

    /// The item's thumbnail covering `size` pixels, made if it hasn't been.
    /// Nil for audio, or for a file that can't be read.
    public func thumbnail(for item: MediaItem, at url: URL, filling size: CGSize) async -> CGImage? {
        guard item.kind != .audio else { return nil }
        let key = Key(mediaID: item.id, size: size)
        if let image = images[key] {
            touch(key)
            return image
        }
        if let task = inFlight[key] { return await task.value }

        let store = store
        let kind = item.kind
        let task = Task.detached(priority: .utility) { () -> CGImage? in
            if let image = await store?.thumbnail(for: key) { return image }
            guard let image = try? await ThumbnailGenerator.thumbnail(of: url, kind: kind, filling: key.size) else {
                return nil
            }
            await store?.store(image, for: key)
            return image
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { insert(image, for: key) }
        return image
    }

    /// Forgets an item's thumbnails, such as when it leaves the library.
    public func removeThumbnails(for mediaID: MediaItem.ID) {
        images = images.filter { $0.key.mediaID != mediaID }
        recency.removeAll { $0.mediaID == mediaID }
    }

    private func insert(_ image: CGImage, for key: Key) {
        images[key] = image
        touch(key)
        while recency.count > capacity {
            images[recency.removeFirst()] = nil
        }
    }

    private func touch(_ key: Key) {
        recency.removeAll { $0 == key }
        recency.append(key)
    }
}

/// Somewhere thumbnails outlast the cache in memory, such as files in the
/// project package's cache.
public protocol ThumbnailStore: Sendable {
    func thumbnail(for key: ThumbnailCache.Key) async -> CGImage?
    func store(_ image: CGImage, for key: ThumbnailCache.Key) async
}
