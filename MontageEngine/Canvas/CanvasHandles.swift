import CoreGraphics
import CoreMedia
import Foundation

/// A part of a layer to take hold of in the preview.
public enum TransformHandle: Equatable, Hashable, Sendable {
    /// The picture itself, to move it.
    case move
    /// A corner, to scale it about its centre.
    case scale
    /// The handle off its top edge, to turn it about its centre.
    case rotate
}

extension ClipTransform {
    /// Changes the transform at a time as a handle is dragged from one point
    /// of the frame to another, in render pixels. Each value is set as
    /// `Animatable.set(_:at:)` sets it: a keyframe at the time for one
    /// that's animated, and the value throughout for one that isn't.
    ///
    /// Call it on the transform as it was when the drag began, with the
    /// drag's starting point, so the change is the drag's as a whole.
    public mutating func drag(
        _ handle: TransformHandle, from start: CGPoint, to end: CGPoint, renderSize: CGSize, at time: CMTime
    ) {
        guard renderSize.width > 0, renderSize.height > 0 else { return }
        let position = position.value(at: time)
        let center = CGPoint(x: position.x * renderSize.width, y: position.y * renderSize.height)
        switch handle {
        case .move:
            self.position.set(CGPoint(
                x: position.x + (end.x - start.x) / renderSize.width,
                y: position.y + (end.y - start.y) / renderSize.height
            ), at: time)
        case .scale:
            let startDistance = hypot(start.x - center.x, start.y - center.y)
            guard startDistance > 1 else { return }
            let ratio = hypot(end.x - center.x, end.y - center.y) / startDistance
            scale.set(min(max(scale.value(at: time) * ratio, Self.scaleRange.lowerBound), Self.scaleRange.upperBound), at: time)
        case .rotate:
            guard let turn = CanvasMath.turn(from: start, to: end, about: center) else { return }
            rotation.set(rotation.value(at: time) + turn, at: time)
        }
    }

    /// How small and how large a handle can scale a picture.
    public static let scaleRange = 0.01...20.0
}

/// A part of a mask's box to take hold of in the preview.
public enum MaskHandle: Equatable, Hashable, Sendable {
    /// The box, to move it.
    case move
    /// A corner or the middle of a side, to size the box about its centre.
    /// Each of x and y is -1 for the left or top, 1 for the right or
    /// bottom, and 0 for the middle.
    case resize(x: Int, y: Int)
    /// The handle off the top of the box, to turn it about its centre.
    case rotate
    /// The handle beyond the right side, as far out as the edge is soft.
    case feather
    /// One of a path mask's points.
    case vertex(Int)
}

/// Where a mask is in the frame, as the preview draws it over a layer.
///
/// A mask is measured against the layer's fitted picture, before the clip's
/// transform: its centre and size as fractions of the picture, its feather as
/// a fraction of the picture's width. The box is turned about its centre in
/// the picture's pixels, then the whole picture goes where the clip's
/// transform takes it.
public struct MaskPlacement: Equatable, Sendable {
    public var layer: LayerPlacement
    /// The box's centre, in the fitted picture's pixels.
    public var center: CGPoint
    /// The box's size, in the fitted picture's pixels.
    public var size: CGSize
    /// Clockwise, in degrees.
    public var rotation: Double
    /// The soft edge's width, in the fitted picture's pixels.
    public var feather: Double
    public var path: MaskPath

    public init(_ mask: Mask, in layer: LayerPlacement, at time: CMTime) {
        let picture = layer.pictureRect
        let center = mask.center.value(at: time)
        let size = mask.size.value(at: time)
        self.layer = layer
        self.center = CGPoint(x: picture.minX + center.x * picture.width, y: picture.minY + center.y * picture.height)
        self.size = CGSize(width: max(0, size.width * picture.width), height: max(0, size.height * picture.height))
        rotation = mask.rotation.value(at: time)
        feather = max(0, mask.feather.value(at: time) * picture.width)
        path = mask.path.value(at: time)
    }

    /// Where a point of the box shows in the frame, given in the box's own
    /// terms: (0, 0) its top-left corner, (1, 1) its bottom-right.
    public func point(inBox fraction: CGPoint) -> CGPoint {
        picturePoint(local: CGPoint(x: (fraction.x - 0.5) * size.width, y: (fraction.y - 0.5) * size.height))
            .applying(layer.transform)
    }

    /// The point `offset` pixels of the picture from the box's centre, along
    /// the box's own axes, where it shows in the frame.
    public func point(fromCenter offset: CGPoint) -> CGPoint {
        picturePoint(local: offset).applying(layer.transform)
    }

    /// The box's corners where they show: top left, top right, bottom
    /// right, bottom left.
    public var corners: [CGPoint] {
        [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(point(inBox:))
    }

    /// Where a handle shows in the frame; `rotate` is `reach` frame pixels
    /// off the top, so it's clear of the box however small.
    public func point(of handle: MaskHandle, reach: Double = 0) -> CGPoint {
        switch handle {
        case .move:
            return point(inBox: CGPoint(x: 0.5, y: 0.5))
        case .resize(let x, let y):
            return point(inBox: CGPoint(x: 0.5 + Double(x) / 2, y: 0.5 + Double(y) / 2))
        case .rotate:
            // The clip's transform scales evenly, so reach in the frame is
            // reach over its scale in the picture.
            let scale = hypot(layer.transform.a, layer.transform.b)
            return point(fromCenter: CGPoint(x: 0, y: -size.height / 2 - (scale > 0 ? reach / scale : 0)))
        case .feather:
            return point(fromCenter: CGPoint(x: size.width / 2 + feather, y: 0))
        case .vertex(let index):
            guard path.vertices.indices.contains(index) else { return point(of: .move) }
            return point(inBox: path.vertices[index].point)
        }
    }

    /// A point of the picture from one along the box's axes, from its centre.
    private func picturePoint(local: CGPoint) -> CGPoint {
        let angle = rotation * .pi / 180
        return CGPoint(
            x: center.x + local.x * cos(angle) - local.y * sin(angle),
            y: center.y + local.x * sin(angle) + local.y * cos(angle)
        )
    }

    /// A point of the frame along the box's axes, from its centre, in the
    /// picture's pixels.
    func local(fromRender point: CGPoint) -> CGPoint? {
        guard let picture = layer.picturePoint(fromRender: point) else { return nil }
        let angle = -rotation * .pi / 180
        let dx = picture.x - center.x
        let dy = picture.y - center.y
        return CGPoint(x: dx * cos(angle) - dy * sin(angle), y: dx * sin(angle) + dy * cos(angle))
    }
}

extension Mask {
    /// Changes the mask at a time as one of its handles is dragged from one
    /// point of the frame to another, in render pixels, over the layer it's
    /// on. As with `ClipTransform.drag`, animated values get a keyframe at
    /// the time and the rest change throughout; call it on the mask as it
    /// was when the drag began.
    public mutating func drag(_ handle: MaskHandle, from start: CGPoint, to end: CGPoint, in layer: LayerPlacement, at time: CMTime) {
        let placement = MaskPlacement(self, in: layer, at: time)
        let picture = layer.pictureRect
        guard picture.width > 0, picture.height > 0,
              let startPoint = layer.picturePoint(fromRender: start), let endPoint = layer.picturePoint(fromRender: end),
              let local = placement.local(fromRender: end) else { return }
        switch handle {
        case .move:
            let center = center.value(at: time)
            self.center.set(CGPoint(
                x: center.x + (endPoint.x - startPoint.x) / picture.width,
                y: center.y + (endPoint.y - startPoint.y) / picture.height
            ), at: time)
        case .resize(let x, let y):
            var size = size.value(at: time)
            if x != 0 { size.width = max(abs(local.x) * 2, 1) / picture.width }
            if y != 0 { size.height = max(abs(local.y) * 2, 1) / picture.height }
            self.size.set(size, at: time)
        case .rotate:
            guard let turn = CanvasMath.turn(from: startPoint, to: endPoint, about: placement.center) else { return }
            rotation.set(rotation.value(at: time) + turn, at: time)
        case .feather:
            feather.set(max(0, abs(local.x) - placement.size.width / 2) / picture.width, at: time)
        case .vertex(let index):
            var path = path.value(at: time)
            guard path.vertices.indices.contains(index), placement.size.width > 0, placement.size.height > 0 else { return }
            path.vertices[index].point = CGPoint(
                x: local.x / placement.size.width + 0.5, y: local.y / placement.size.height + 0.5
            )
            self.path.set(path, at: time)
        }
    }
}

enum CanvasMath {
    /// How far, in degrees clockwise (y running down), a point has turned
    /// about a centre, the short way round. Nil when either point is on the
    /// centre, where there's no angle to measure.
    static func turn(from start: CGPoint, to end: CGPoint, about center: CGPoint) -> Double? {
        let startVector = CGPoint(x: start.x - center.x, y: start.y - center.y)
        let endVector = CGPoint(x: end.x - center.x, y: end.y - center.y)
        guard hypot(startVector.x, startVector.y) > 1e-6, hypot(endVector.x, endVector.y) > 1e-6 else { return nil }
        var degrees = (atan2(endVector.y, endVector.x) - atan2(startVector.y, startVector.x)) * 180 / .pi
        if degrees > 180 { degrees -= 360 }
        if degrees < -180 { degrees += 360 }
        return degrees
    }
}
