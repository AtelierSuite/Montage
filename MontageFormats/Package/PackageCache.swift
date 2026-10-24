import CoreGraphics
import Foundation
import ImageIO
import MontageEngine
import Synchronization
import UniformTypeIdentifiers

/// Thumbnails and waveforms kept in the project package's `Cache/` folder,
/// so they're made once rather than every time the project's opened:
///
///     Cache/
///     ├── Thumbnails/<media ID>/220x124.jpg          the library's pictures
///     ├── Thumbnails/<media ID>/h60/2000.jpg         timeline frames, by height, then milliseconds
///     ├── Waveforms/<media ID>.peaks                 `WaveformPeaks.encoded()`
///     └── Stereo/<media ID>.m4a                      mono media's sound on both channels
///
/// Files are written straight into the package on disk as they're made,
/// between saves, and `ProjectPackage` keeps the folder whenever it writes
/// the package. Nothing in it is needed: the folder may be deleted at any
/// time, and whatever's missing is made again from the media when it's next
/// asked for. Until the project is first saved there's nowhere to keep
/// anything, and the caches in memory are all there is.
public final class PackageCache: MediaCacheStore, DerivedMediaStore, Sendable {
    static let thumbnailsDirectoryName = "Thumbnails"
    static let waveformsDirectoryName = "Waveforms"

    private let location: Mutex<URL?>

    public init(packageURL: URL? = nil) {
        location = Mutex(packageURL)
    }

    /// Where the project's package is on disk, once it has been saved. Set
    /// whenever it changes, as `PackageMediaStore.packageURL` is.
    public var packageURL: URL? {
        get { location.withLock { $0 } }
        set { location.withLock { $0 = newValue } }
    }

    private var cacheDirectory: URL? {
        packageURL.map(ProjectPackage.cacheDirectory(inPackageAt:))
    }

    // MARK: - Thumbnails

    public func thumbnail(for key: ThumbnailCache.Key) async -> CGImage? {
        guard let base = thumbnailURL(for: key) else { return nil }
        for pathExtension in ["jpg", "png"] {
            let url = base.appendingPathExtension(pathExtension)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            return image
        }
        return nil
    }

    public func store(_ image: CGImage, for key: ThumbnailCache.Key) async {
        guard let base = thumbnailURL(for: key) else { return }
        // JPEG, unless the picture has see-through parts to keep.
        let type: UTType = switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: .jpeg
        default: .png
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        write(data as Data, to: base.appendingPathExtension(type == .jpeg ? "jpg" : "png"))
    }

    /// The file for a key, without its extension.
    private func thumbnailURL(for key: ThumbnailCache.Key) -> URL? {
        guard let folder = thumbnailsDirectory(for: key.mediaID) else { return nil }
        if let milliseconds = key.milliseconds {
            return folder.appending(path: "h\(key.height)", directoryHint: .isDirectory)
                .appending(path: String(milliseconds), directoryHint: .notDirectory)
        }
        return folder.appending(path: "\(key.width)x\(key.height)", directoryHint: .notDirectory)
    }

    private func thumbnailsDirectory(for mediaID: MediaItem.ID) -> URL? {
        cacheDirectory?.appending(path: Self.thumbnailsDirectoryName, directoryHint: .isDirectory)
            .appending(path: mediaID.uuidString, directoryHint: .isDirectory)
    }

    // MARK: - Waveforms

    public func waveform(for mediaID: MediaItem.ID) async -> WaveformPeaks? {
        guard let url = waveformURL(for: mediaID), let data = try? Data(contentsOf: url) else { return nil }
        return WaveformPeaks(encoded: data)
    }

    public func store(_ waveform: WaveformPeaks, for mediaID: MediaItem.ID) async {
        guard let url = waveformURL(for: mediaID) else { return }
        write(waveform.encoded(), to: url)
    }

    private func waveformURL(for mediaID: MediaItem.ID) -> URL? {
        cacheDirectory?.appending(path: Self.waveformsDirectoryName, directoryHint: .isDirectory)
            .appending(path: "\(mediaID.uuidString).peaks", directoryHint: .notDirectory)
    }

    // MARK: - Copies of media

    public func url(for mediaID: MediaItem.ID, _ kind: DerivedMedia) -> URL? {
        let (folder, pathExtension) = switch kind {
        case .stereoAudio: ("Stereo", "m4a")
        }
        return cacheDirectory?.appending(path: folder, directoryHint: .isDirectory)
            .appending(path: "\(mediaID.uuidString).\(pathExtension)", directoryHint: .notDirectory)
    }

    // MARK: - Clearing

    /// Throws away everything made from a media item, such as when it's
    /// relinked to another file and what was made from the old one is wrong.
    public func removeCache(for mediaID: MediaItem.ID) {
        if let folder = thumbnailsDirectory(for: mediaID) { try? FileManager.default.removeItem(at: folder) }
        if let url = waveformURL(for: mediaID) { try? FileManager.default.removeItem(at: url) }
        for kind in DerivedMedia.allCases {
            if let url = url(for: mediaID, kind) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Writes a file of the cache, making its folder if need be. A write
    /// that fails is let go: the file is made again next time.
    private func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
