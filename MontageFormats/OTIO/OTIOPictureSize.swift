import CoreGraphics
import Foundation
import ImageIO

/// The size of a picture file's frames, read straight from the file while a
/// timeline is imported, before its media is gathered and probed. Resolve
/// moves a clip by fractions of its picture as fitted into the frame, so
/// the picture's shape is needed then.
enum OTIOPictureSize {
    /// The frames' stored size and the clockwise turn that shows them
    /// upright, for a still image or a QuickTime or MPEG-4 movie. Nil when
    /// the file can't be read here.
    static func read(at url: URL) -> (size: CGSize, rotation: Int)? {
        guard url.isFileURL else { return nil }
        return image(at: url) ?? movie(at: url)
    }

    private static func image(at url: URL) -> (size: CGSize, rotation: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else { return nil }
        let rotation = switch (properties[kCGImagePropertyOrientation] as? UInt32).flatMap(CGImagePropertyOrientation.init) {
        case .down, .downMirrored: 180
        case .right, .rightMirrored: 90
        case .left, .leftMirrored: 270
        default: 0
        }
        return (CGSize(width: width, height: height), rotation)
    }

    // MARK: - Movies

    /// The first picture track's size from its track header (`tkhd`), and
    /// its turn from the header's matrix.
    private static func movie(at url: URL) -> (size: CGSize, rotation: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // The movie box can sit after the media, so the top-level boxes are
        // stepped over without reading them.
        var offset: UInt64 = 0
        for _ in 0..<64 {
            guard (try? handle.seek(toOffset: offset)) != nil, let header = try? handle.read(upToCount: 16), header.count >= 8 else {
                return nil
            }
            var size = UInt64(header.bigUInt32(at: 0))
            let type = header.fourCC(at: 4)
            var headerLength: UInt64 = 8
            if size == 1, header.count >= 16 {
                size = header.bigUInt64(at: 8)
                headerLength = 16
            }
            if type == "moov" {
                // A movie box is small beside the media; a huge one isn't a movie.
                let length = size == 0 ? 8 << 20 : size - headerLength
                guard length <= 64 << 20, let body = try? handle.read(upToCount: Int(length)) else { return nil }
                return pictureTrack(in: body)
            }
            guard size >= headerLength else { return nil }
            offset += size
        }
        return nil
    }

    private static func pictureTrack(in movie: Data) -> (size: CGSize, rotation: Int)? {
        for track in boxes(in: movie) where track.type == "trak" {
            let parts = boxes(in: track.body)
            let handler = parts.first { $0.type == "mdia" }.flatMap { boxes(in: $0.body).first { $0.type == "hdlr" } }
            guard let handler, handler.body.count >= 12, handler.body.fourCC(at: 8) == "vide",
                  let header = parts.first(where: { $0.type == "tkhd" })?.body else { continue }
            // Version 1 has 64-bit times.
            let matrix = header.first == 1 ? 52 : 40
            guard header.count >= matrix + 44 else { continue }
            let width = Double(header.bigUInt32(at: matrix + 36)) / 65536
            let height = Double(header.bigUInt32(at: matrix + 40)) / 65536
            guard width > 0, height > 0 else { continue }
            // The matrix's a and b, 16.16 fixed point: (0, 1) turns a
            // quarter clockwise, (0, -1) a quarter back, (-1, 0) half way.
            let a = Int32(bitPattern: header.bigUInt32(at: matrix))
            let b = Int32(bitPattern: header.bigUInt32(at: matrix + 4))
            let rotation = a == 0 ? (b > 0 ? 90 : 270) : (a < 0 ? 180 : 0)
            return (CGSize(width: width, height: height), rotation)
        }
        return nil
    }

    /// The boxes one after another in a box's body.
    private static func boxes(in data: Data) -> [(type: String, body: Data)] {
        var found: [(String, Data)] = []
        var offset = data.startIndex
        while data.endIndex - offset >= 8 {
            let size = Int(data.bigUInt32(at: offset - data.startIndex))
            let type = data.fourCC(at: offset - data.startIndex + 4)
            let end = size == 0 ? data.endIndex : offset + size
            guard size == 0 || size >= 8, end <= data.endIndex else { break }
            found.append((type, data[(offset + 8)..<end]))
            offset = end
        }
        return found
    }
}

private extension Data {
    func bigUInt32(at index: Int) -> UInt32 {
        let start = startIndex + index
        return self[start..<(start + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func bigUInt64(at index: Int) -> UInt64 {
        UInt64(bigUInt32(at: index)) << 32 | UInt64(bigUInt32(at: index + 4))
    }

    func fourCC(at index: Int) -> String {
        let start = startIndex + index
        return String(decoding: self[start..<(start + 4)], as: UTF8.self)
    }
}
