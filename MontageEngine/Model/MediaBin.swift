import Foundation

/// A folder of the library, to file media in. Bins only sort the library:
/// filing an item in one changes nothing about its clips.
public struct MediaBin: Identifiable, Equatable, Sendable, Codable {
    public typealias ID = UUID

    public var id: ID
    public var name: String

    public init(id: ID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}
