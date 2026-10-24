import CoreGraphics
import CoreMedia

/// Where the project's frame is drawn in a view showing it, fitted in and
/// centred as the player draws it, and the way between the view's points
/// and the frame's own (render) pixels. Both have y running down from the
/// top-left corner.
public struct PreviewMapping: Equatable, Sendable {
    /// The project's frame size, which clip transforms and masks work in.
    public var renderSize: CGSize
    /// Where the frame is drawn in the view.
    public var pictureRect: CGRect

    public init(renderSize: CGSize, viewSize: CGSize) {
        self.renderSize = renderSize
        pictureRect = Self.fit(renderSize, in: CGRect(origin: .zero, size: viewSize))
    }

    /// The view's points for each of the frame's pixels.
    public var scale: Double {
        renderSize.width > 0 ? pictureRect.width / renderSize.width : 0
    }

    /// A point in the frame, from one in the view.
    public func renderPoint(fromView point: CGPoint) -> CGPoint {
        guard scale > 0 else { return .zero }
        return CGPoint(x: (point.x - pictureRect.minX) / scale, y: (point.y - pictureRect.minY) / scale)
    }

    /// A point in the view, from one in the frame.
    public func viewPoint(fromRender point: CGPoint) -> CGPoint {
        CGPoint(x: pictureRect.minX + point.x * scale, y: pictureRect.minY + point.y * scale)
    }

    /// A size, centred in a rectangle and as large as fits keeping its shape.
    /// A size without area fills the rectangle.
    public static func fit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let scale = min(rect.width / size.width, rect.height / size.height)
        let width = size.width * scale
        let height = size.height * scale
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }
}

/// Where one layer's picture is in the frame at a time: fitted into the
/// frame as the compositor fits it, then moved by the clip's transform. In
/// render pixels, y running down.
public struct LayerPlacement: Equatable, Sendable {
    public var clipID: Clip.ID
    /// The picture fitted into the frame, before the clip's transform: the
    /// frame the clip's effects and masks are measured against.
    public var pictureRect: CGRect
    /// The clip's transform at the time, from the fitted picture to where it
    /// shows.
    public var transform: CGAffineTransform

    public init(clipID: Clip.ID, pictureRect: CGRect, transform: CGAffineTransform) {
        self.clipID = clipID
        self.pictureRect = pictureRect
        self.transform = transform
    }

    /// `pictureSize` is the clip's picture the way up it's shown; a size
    /// without area, as for a layer that draws its own picture, covers the
    /// frame.
    public init(clip: Clip, pictureSize: CGSize, renderSize: CGSize, at clipTime: CMTime) {
        self.init(
            clipID: clip.id,
            pictureRect: PreviewMapping.fit(pictureSize, in: CGRect(origin: .zero, size: renderSize)),
            transform: FrameComposer.clipTransform(clip.transform, renderSize: renderSize, at: clipTime)
        )
    }

    /// Where the picture's centre shows.
    public var center: CGPoint {
        point(inPicture: CGPoint(x: 0.5, y: 0.5))
    }

    /// The picture's corners where they show: top left, top right, bottom
    /// right, bottom left.
    public var corners: [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(point(inPicture:))
    }

    /// Where a point of the picture shows, given as a fraction of the picture:
    /// (0, 0) its top-left corner, (1, 1) its bottom-right.
    public func point(inPicture fraction: CGPoint) -> CGPoint {
        CGPoint(x: pictureRect.minX + fraction.x * pictureRect.width, y: pictureRect.minY + fraction.y * pictureRect.height)
            .applying(transform)
    }

    /// The point of the fitted picture, before the clip's transform, that
    /// shows at a point of the frame. Nil for a layer scaled to nothing.
    public func picturePoint(fromRender point: CGPoint) -> CGPoint? {
        guard abs(transform.a * transform.d - transform.b * transform.c) > 1e-12 else { return nil }
        return point.applying(transform.inverted())
    }

    /// Whether the picture covers a point of the frame.
    public func contains(_ point: CGPoint) -> Bool {
        guard let picturePoint = picturePoint(fromRender: point) else { return false }
        return pictureRect.contains(picturePoint)
    }
}

extension Project {
    /// The size of a clip's picture the way up it's shown, which the
    /// compositor fits into the frame; zero when it has none of its own.
    public func pictureSize(of clip: Clip) -> CGSize {
        mediaItem(id: clip.mediaID)?.metadata.presentationSize ?? .zero
    }

    /// The layers showing at a time on the timeline, bottom first, as the
    /// compositor draws them: the clips at the time on video tracks that
    /// aren't hidden, and that aren't faded out. `excluding` leaves out
    /// clips the composition couldn't show, such as those over the limit of
    /// layers.
    public func layerPlacements(at time: CMTime, excluding: Set<Clip.ID> = []) -> [LayerPlacement] {
        let renderSize = settings.renderSize
        return tracks.filter { $0.kind == .video && !$0.isHidden }.flatMap { track in
            track.clips.filter { clip in
                clip.timelineRange.containsTime(time) && !excluding.contains(clip.id)
                    && clip.opacity.value(at: clip.localTime(time)) > 0
            }.map { clip in
                LayerPlacement(clip: clip, pictureSize: pictureSize(of: clip), renderSize: renderSize, at: clip.localTime(time))
            }
        }
    }

    /// The topmost layer whose picture covers a point of the frame at a time.
    public func layer(at point: CGPoint, time: CMTime, excluding: Set<Clip.ID> = []) -> LayerPlacement? {
        layerPlacements(at: time, excluding: excluding).last { $0.contains(point) }
    }
}
