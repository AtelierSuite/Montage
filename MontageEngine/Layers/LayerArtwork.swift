import CoreGraphics
import CoreMedia
import Synchronization

/// The pictures of text and shape clips, drawn when the compositor asks for
/// them and kept, so a layer is drawn again only when something about how it
/// looks has changed: an edit, or a keyframed value moving on.
public final class LayerArtwork: Sendable {
    /// Shared by every compositor.
    public static let shared = LayerArtwork(byteLimit: 256 * 1024 * 1024)

    private enum Key: Hashable {
        case text(TextContent.Resolved, scale: Double)
        case shape(ShapeContent.Resolved, scale: Double)
    }

    private struct Cache {
        var pictures: [Key: DrawnLayer?] = [:]
        /// Least recently used first.
        var order: [Key] = []
        /// How much memory the kept pictures take.
        var bytes = 0
        var drawCount = 0
    }

    /// The most memory the kept pictures may take; the least recently used
    /// go first past it. One picture bigger than it is still kept, alone.
    private let byteLimit: Int
    private let cache = Mutex(Cache())

    init(byteLimit: Int) {
        self.byteLimit = byteLimit
    }

    private static func cost(of picture: DrawnLayer?) -> Int {
        picture.map { $0.image.bytesPerRow * $0.image.height } ?? 0
    }

    /// How many pictures have been drawn rather than found kept.
    var drawCount: Int { cache.withLock { $0.drawCount } }

    /// The picture of a text or shape clip at a time from its start, drawn
    /// at `scale` of its pixels to each of a frame of `renderSize`'s. Nil
    /// for other clips, and for text or a shape with nothing to draw.
    func picture(of content: ClipContent, at clipTime: CMTime, renderSize: CGSize, scale: Double) -> DrawnLayer? {
        let key: Key
        switch content {
        case .text(let text): key = .text(text.resolved(at: clipTime, renderSize: renderSize), scale: scale)
        case .shape(let shape): key = .shape(shape.resolved(at: clipTime), scale: scale)
        case .media, .image: return nil
        }
        if let kept = cache.withLock({ cache -> DrawnLayer?? in
            guard let picture = cache.pictures[key] else { return nil }
            cache.order.removeAll { $0 == key }
            cache.order.append(key)
            return picture
        }) {
            return kept
        }
        // Drawn outside the lock, so other layers aren't held up.
        let picture: DrawnLayer? = switch key {
        case .text(let text, let scale): TextRenderer.image(of: text, scale: scale)
        case .shape(let shape, let scale): ShapeRenderer.image(of: shape, scale: scale)
        }
        cache.withLock { cache in
            cache.drawCount += 1
            if let replaced = cache.pictures.updateValue(picture, forKey: key) {
                cache.bytes -= Self.cost(of: replaced)
            } else {
                cache.order.append(key)
            }
            cache.bytes += Self.cost(of: picture)
            while cache.bytes > byteLimit, cache.order.count > 1 {
                let oldest = cache.order.removeFirst()
                cache.bytes -= Self.cost(of: cache.pictures.removeValue(forKey: oldest) ?? nil)
            }
        }
        return picture
    }

    /// The scale to draw a layer at: enough pixels for the size the frame is
    /// drawn at, and for the layer's own scale, so it stays sharp when it's
    /// made bigger. Kept to steps, so a layer zooming in is drawn again only
    /// now and then, not every frame.
    static func drawingScale(outputScale: Double, layerScale: Double) -> Double {
        let wanted = max(outputScale * max(abs(layerScale), 1), 0.05)
        // Half steps of a doubling.
        let step = (log2(wanted) * 2).rounded(.up) / 2
        return min(pow(2, step), 8)
    }
}
