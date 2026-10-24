import Foundation

/// Finds the files behind media items. The model only knows where media is
/// relative to the project; whoever has the project open knows where the
/// project is, and makes one of these to say.
public struct MediaResolver: Sendable {
    private let resolve: @Sendable (MediaItem) -> URL?
    private let derive: @Sendable (MediaItem, DerivedMedia) -> URL?

    public init(_ resolve: @escaping @Sendable (MediaItem) -> URL?) {
        self.resolve = resolve
        derive = { _, _ in nil }
    }

    private init(
        resolve: @escaping @Sendable (MediaItem) -> URL?, derive: @escaping @Sendable (MediaItem, DerivedMedia) -> URL?
    ) {
        self.resolve = resolve
        self.derive = derive
    }

    /// The item's file, or nil if it can't be found.
    public func url(for item: MediaItem) -> URL? {
        resolve(item)
    }

    /// A copy made from the item's file to play in its place, or nil if
    /// there isn't one.
    public func url(for item: MediaItem, _ kind: DerivedMedia) -> URL? {
        derive(item, kind)
    }

    /// The resolver, also finding copies made from media: whatever `derive`
    /// finds, or what this one already did where it finds nothing.
    public func addingDerivedMedia(_ derive: @escaping @Sendable (MediaItem, DerivedMedia) -> URL?) -> MediaResolver {
        let previous = self.derive
        return MediaResolver(resolve: resolve) { item, kind in derive(item, kind) ?? previous(item, kind) }
    }

    /// Finds nothing, for a project with nowhere to look yet.
    public static let none = MediaResolver { _ in nil }
}
