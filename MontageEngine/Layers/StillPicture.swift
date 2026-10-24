import CoreGraphics
import CoreImage
import Foundation
import ImageIO

/// A still image's picture, read once when the composition is built and
/// shown by the compositor for every frame of its clips.
final class StillPicture: @unchecked Sendable {
    /// Upright, in sRGB, with its transparency.
    let image: CIImage
    let size: CGSize

    private init(_ image: CGImage) {
        self.image = CIImage(cgImage: image)
        size = CGSize(width: image.width, height: image.height)
    }

    /// Reads an image file, turned upright as it says to show it, and no
    /// bigger along its longer side than `maximumSide`, so a large photo
    /// doesn't use more memory than the frame can show.
    static func load(_ url: URL, maximumSide: Double) -> StillPicture? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maximumSide)),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return redrawnInSRGB(image).map(StillPicture.init)
    }

    /// The compositor blends colours as they're stored, as video's are, so
    /// an image in another colour space, such as a phone's Display P3, is
    /// turned into sRGB first.
    private static func redrawnInSRGB(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }
}
