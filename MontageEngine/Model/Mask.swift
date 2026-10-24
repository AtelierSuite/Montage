import CoreGraphics

/// Limits an effect to part of the picture: a rectangle, an ellipse or a
/// path of its own, or everything outside one once inverted.
///
/// The mask is a box placed in the frame, turned about its centre; the
/// rectangle and ellipse fill it, and a path's points are placed within it,
/// so moving or turning the box takes the path along. Every parameter is
/// `Animatable`, so a mask can follow what it covers as it moves.
public struct Mask: Equatable, Sendable {
    public enum Shape: String, Equatable, Sendable, Codable, CaseIterable {
        case rectangle, ellipse, path
    }

    public var shape: Shape
    /// The box's centre, as a fraction of the frame: (0.5, 0.5) is the
    /// middle, (0, 0) the top-left corner.
    public var center: Animatable<CGPoint>
    /// The box's width and height, as fractions of the frame's.
    public var size: Animatable<CGSize>
    /// Clockwise, in degrees.
    public var rotation: Animatable<Double>
    /// How wide the soft edge is, as a fraction of the frame's width; 0 is a
    /// sharp edge.
    public var feather: Animatable<Double>
    /// The outline a `.path` mask follows, in the box: (0, 0) is its
    /// top-left corner, (1, 1) its bottom-right.
    public var path: Animatable<MaskPath>
    /// Turned over, the effect applies everywhere but the shape.
    public var isInverted: Bool

    public init(
        _ shape: Shape, center: CGPoint = CGPoint(x: 0.5, y: 0.5), size: CGSize = CGSize(width: 0.5, height: 0.5),
        rotation: Double = 0, feather: Double = 0, path: MaskPath = .diamond, isInverted: Bool = false
    ) {
        self.shape = shape
        self.center = Animatable(center)
        self.size = Animatable(size)
        self.rotation = Animatable(rotation)
        self.feather = Animatable(feather)
        self.path = Animatable(path)
        self.isInverted = isInverted
    }
}

extension Mask: Codable {
    private enum CodingKeys: String, CodingKey {
        case shape, center, size, rotation, feather, path, isInverted
    }

    // Only the shape is needed to read; the rest fall back to a new mask's.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try container.decode(Shape.self, forKey: .shape))
        center = try container.decodeIfPresent(Animatable<CGPoint>.self, forKey: .center) ?? center
        size = try container.decodeIfPresent(Animatable<CGSize>.self, forKey: .size) ?? size
        rotation = try container.decodeIfPresent(Animatable<Double>.self, forKey: .rotation) ?? rotation
        feather = try container.decodeIfPresent(Animatable<Double>.self, forKey: .feather) ?? feather
        path = try container.decodeIfPresent(Animatable<MaskPath>.self, forKey: .path) ?? path
        isInverted = try container.decodeIfPresent(Bool.self, forKey: .isInverted) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(shape, forKey: .shape)
        try container.encode(center, forKey: .center)
        try container.encode(size, forKey: .size)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(feather, forKey: .feather)
        try container.encode(path, forKey: .path)
        try container.encode(isInverted, forKey: .isInverted)
    }
}

/// A closed outline of points joined by straight lines or curves.
public struct MaskPath: Equatable, Sendable, Codable {
    /// A point on the outline, with the handles that bend the curve through
    /// it. Handles are offsets from the point; at zero, the outline turns a
    /// sharp corner there.
    public struct Vertex: Equatable, Sendable, Codable {
        public var point: CGPoint
        /// Where the curve arriving at the point comes from.
        public var inHandle: CGPoint
        /// Where the curve leaving the point heads.
        public var outHandle: CGPoint

        public init(_ point: CGPoint, inHandle: CGPoint = .zero, outHandle: CGPoint = .zero) {
            self.point = point
            self.inHandle = inHandle
            self.outHandle = outHandle
        }
    }

    public var vertices: [Vertex]

    public init(_ vertices: [Vertex]) {
        self.vertices = vertices
    }

    /// A diamond touching the middle of each side of the box.
    public static let diamond = MaskPath([
        Vertex(CGPoint(x: 0.5, y: 0)), Vertex(CGPoint(x: 1, y: 0.5)),
        Vertex(CGPoint(x: 0.5, y: 1)), Vertex(CGPoint(x: 0, y: 0.5)),
    ])

    /// The outline as a Core Graphics path, each point put through
    /// `transform`. Fewer than three points enclose nothing, and make an
    /// empty path.
    public func cgPath(transform: CGAffineTransform = .identity) -> CGPath {
        let path = CGMutablePath()
        guard vertices.count >= 3, let first = vertices.first else { return path }
        path.move(to: first.point, transform: transform)
        for (from, to) in zip(vertices, vertices.dropFirst() + [first]) {
            if from.outHandle == .zero && to.inHandle == .zero {
                path.addLine(to: to.point, transform: transform)
            } else {
                path.addCurve(
                    to: to.point,
                    control1: CGPoint(x: from.point.x + from.outHandle.x, y: from.point.y + from.outHandle.y),
                    control2: CGPoint(x: to.point.x + to.inHandle.x, y: to.point.y + to.inHandle.y),
                    transform: transform
                )
            }
        }
        path.closeSubpath()
        return path
    }
}

// Paths with as many points blend point by point, so a path keyframed at
// one shape and then another morphs between them. Paths with different
// numbers of points can't be matched up, and hold until the next keyframe.
extension MaskPath: Interpolatable {
    public static func interpolate(from: MaskPath, to: MaskPath, fraction: Double) -> MaskPath {
        guard from.vertices.count == to.vertices.count else { return fraction < 1 ? from : to }
        return MaskPath(zip(from.vertices, to.vertices).map { from, to in
            Vertex(.interpolate(from: from.point, to: to.point, fraction: fraction),
                   inHandle: .interpolate(from: from.inHandle, to: to.inHandle, fraction: fraction),
                   outHandle: .interpolate(from: from.outHandle, to: to.outHandle, fraction: fraction))
        })
    }
}
