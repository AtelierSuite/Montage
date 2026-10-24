import CoreMedia
import Foundation

/// A point on the timeline the user has marked, to find again and to snap
/// edits to.
public struct Marker: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Where it is on the timeline.
    public var time: CMTime
    /// Empty for a marker that hasn't been named.
    public var name: String

    public init(id: UUID = UUID(), time: CMTime, name: String = "") {
        self.id = id
        self.time = time
        self.name = name
    }
}

extension Marker: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, time, name
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        time = try container.decode(CMTime.self, forKey: .time)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(time, forKey: .time)
        try container.encode(name, forKey: .name)
    }
}

extension Project {
    /// Marks a time on the timeline. A time already marked keeps its marker,
    /// whose ID is returned.
    @discardableResult
    public mutating func addMarker(at time: CMTime, name: String = "") -> Marker.ID {
        if let existing = markers.first(where: { $0.time == time }) { return existing.id }
        let marker = Marker(time: time, name: name)
        let index = markers.firstIndex { $0.time > time } ?? markers.endIndex
        markers.insert(marker, at: index)
        return marker.id
    }

    public mutating func removeMarkers(_ ids: Set<Marker.ID>) {
        markers.removeAll { ids.contains($0.id) }
    }
}
