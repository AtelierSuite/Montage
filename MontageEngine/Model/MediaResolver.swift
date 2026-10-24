import Foundation

/// Finds the files behind media items. The model only knows where media is
/// relative to the project; whoever has the project open knows where the
/// project is, and makes one of these to say.
public struct MediaResolver: Sendable {
    private let resolve: @Sendable (MediaItem) -> URL?

    public init(_ resolve: @escaping @Sendable (MediaItem) -> URL?) {
        self.resolve = resolve
    }

    /// The item's file, or nil if it can't be found.
    public func url(for item: MediaItem) -> URL? {
        resolve(item)
    }

    /// Finds nothing, for a project with nowhere to look yet.
    public static let none = MediaResolver { _ in nil }
}
