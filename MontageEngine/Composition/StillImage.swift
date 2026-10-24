@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import ImageIO
import Synchronization

/// A still image clip's picture, which the compositor draws in place of the
/// frames of the filler its clip is placed with (see `StillFiller`).
///
/// Only where to find the image is kept: it's decoded when a frame first
/// needs it, and kept in a small cache shared by every compositor, so a
/// timeline full of photos doesn't hold them all at once.
struct StillImage: Sendable {
    let url: URL
    /// The image's size shown upright, as stored.
    let size: CGSize

    /// Reads the image's size, without decoding it. Nil when the file isn't
    /// an image that can be read.
    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        let isTurned = MediaProbe.rotation(for: orientation) % 180 != 0
        self.url = url
        self.size = isTurned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// The image upright, as `size` with its origin at zero, for a frame of
    /// `renderSize`. Nil when it can't be decoded.
    func picture(for renderSize: CGSize) -> CIImage? {
        // Twice the frame's size leaves room to zoom in before it softens.
        let maxPixelSize = Int(max(renderSize.width, renderSize.height) * 2)
        guard let image = Self.cache.image(for: url, maxPixelSize: maxPixelSize) else { return nil }
        let picture = CIImage(cgImage: image)
        return picture.transformed(by: CGAffineTransform(
            scaleX: size.width / picture.extent.width, y: size.height / picture.extent.height
        ))
    }

    private static let cache = StillImageCache()
}

/// Decoded still images, the few most recently used.
private final class StillImageCache: Sendable {
    private struct Key: Hashable {
        let url: URL
        let maxPixelSize: Int
    }

    /// Enough for the images around a cut on a few layers.
    private static let capacity = 6
    private let images = Mutex<[(key: Key, image: CGImage)]>([])

    func image(for url: URL, maxPixelSize: Int) -> CGImage? {
        let key = Key(url: url, maxPixelSize: maxPixelSize)
        if let image = images.withLock({ images -> CGImage? in
            guard let index = images.firstIndex(where: { $0.key == key }) else { return nil }
            let found = images.remove(at: index)
            images.append(found)
            return found.image
        }) {
            return image
        }
        guard let image = Self.decode(url, maxPixelSize: maxPixelSize) else { return nil }
        images.withLock { images in
            images.removeAll { $0.key == key }
            images.append((key, image))
            if images.count > Self.capacity { images.removeFirst(images.count - Self.capacity) }
        }
        return image
    }

    /// The image turned upright, no larger than `maxPixelSize` on its long
    /// side, in sRGB: frames are blended as they're stored, so a photo in a
    /// wider space would otherwise look washed out beside video.
    private static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}

/// A short black movie that still image clips are placed with, since an
/// `AVComposition` can only hold timed media: it keeps the clip's time on its
/// composition track, stretched to the clip's length, and the compositor
/// draws the image over it. Written once per run of the app.
actor StillFiller {
    static let shared = StillFiller()

    private static let frameCount = 30
    private static let frameDuration = CMTime(value: 1, timescale: 30)
    private var written: Task<URL, any Error>?

    /// The movie's file, written the first time it's asked for.
    func url() async throws -> URL {
        if let written, let url = try? await written.value { return url }
        let task = Task { try await Self.write() }
        written = task
        return try await task.value
    }

    private static func write() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Montage Still Filler \(UUID().uuidString).mov")
        let size = 64
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size, AVVideoHeightKey: size,
        ])
        guard writer.canAdd(input) else { throw writer.error ?? StillFillerError.notWritten }
        let receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
        try writer.start()
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, size, size, kCVPixelFormatType_32BGRA, [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
        ] as CFDictionary, &buffer)
        guard let buffer else { throw StillFillerError.notWritten }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        for frame in 0..<frameCount {
            try await receiver.append(
                CVReadOnlyPixelBuffer(unsafeBuffer: buffer), with: CMTimeMultiply(frameDuration, multiplier: Int32(frame))
            )
        }
        receiver.finish()
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frameCount)))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StillFillerError.notWritten }
        return url
    }
}

enum StillFillerError: Error {
    case notWritten
}
