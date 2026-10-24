import CoreMedia
import Foundation

/// What the library shows of the project's media: a bin, the kinds asked
/// for, the items whose names match a search, in an order.
public struct LibraryQuery: Equatable, Sendable {
    public enum Scope: Hashable, Sendable {
        /// Everything, whatever bin it's in.
        case all
        /// What's in one bin.
        case bin(MediaBin.ID)
        /// What's in no bin.
        case unfiled
    }

    public enum Order: String, CaseIterable, Sendable {
        /// The order the media was imported in.
        case imported
        case name
        /// Longest first.
        case duration
        /// Video, then audio, then images, each by name.
        case kind
    }

    public var scope: Scope
    /// The kinds shown. Empty shows every kind.
    public var kinds: Set<MediaItem.Kind>
    /// Words the name must contain, ignoring case and accents. Empty
    /// matches everything.
    public var search: String
    public var order: Order
    /// Only media no clip on the timeline uses.
    public var unusedOnly: Bool

    public init(
        scope: Scope = .all, kinds: Set<MediaItem.Kind> = [], search: String = "", order: Order = .imported,
        unusedOnly: Bool = false
    ) {
        self.scope = scope
        self.kinds = kinds
        self.search = search
        self.order = order
        self.unusedOnly = unusedOnly
    }

    /// Whether the query narrows the library down at all, other than by bin.
    public var isFiltering: Bool {
        !kinds.isEmpty || !search.trimmingCharacters(in: .whitespaces).isEmpty || unusedOnly
    }

    /// The project's media that the query shows, in its order.
    public func items(in project: Project) -> [MediaItem] {
        let words = search.split(whereSeparator: \.isWhitespace)
        let used = unusedOnly ? project.usedMediaIDs : []
        let shown = project.media.filter { item in
            switch scope {
            case .all: break
            case .bin(let id): guard item.binID == id else { return false }
            case .unfiled: guard item.binID == nil else { return false }
            }
            if !kinds.isEmpty, !kinds.contains(item.kind) { return false }
            if unusedOnly, used.contains(item.id) { return false }
            return words.allSatisfy { item.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
        return sorted(shown)
    }

    private func sorted(_ items: [MediaItem]) -> [MediaItem] {
        func byName(_ a: MediaItem, _ b: MediaItem) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        switch order {
        case .imported:
            return items
        case .name:
            return items.sorted(by: byName)
        case .duration:
            return items.sorted { a, b in
                a.metadata.duration == b.metadata.duration ? byName(a, b) : a.metadata.duration > b.metadata.duration
            }
        case .kind:
            let rank: [MediaItem.Kind: Int] = [.video: 0, .audio: 1, .image: 2]
            return items.sorted { a, b in a.kind == b.kind ? byName(a, b) : rank[a.kind]! < rank[b.kind]! }
        }
    }
}
