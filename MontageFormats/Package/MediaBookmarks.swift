import Foundation
import MontageEngine
import Synchronization

/// Media left where it was rather than copied into the package, found again
/// through bookmarks: on the Mac, security-scoped ones, which keep the app's
/// access to a file the user chose across launches.
///
/// A bookmark is resolved the first time its file's asked for, and access to
/// the file is kept from then until this goes away, so playback and export
/// can read it whenever they need. A bookmark can go stale, when its file is
/// moved or the volume it's on is changed: it still finds the file, but
/// should be made again to keep doing so. A fresh one is made then, and kept
/// in `refreshedBookmarks` for whoever owns the project to put in its place.
public final class MediaBookmarks: Sendable {
    private struct Resolved {
        var url: URL
        var isAccessing: Bool
    }

    private struct State {
        var resolved: [Data: Resolved] = [:]
        var refreshed: [Data: Data] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    deinit {
        state.withLock { state in
            for resolved in state.resolved.values where resolved.isAccessing {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }
    }

    // Resolved without mounting, so a project whose media is on a drive
    // that isn't connected opens straight away, with that media missing.
    #if os(macOS)
    private static let creationOptions: URL.BookmarkCreationOptions = [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI, .withoutMounting]
    #else
    private static let creationOptions: URL.BookmarkCreationOptions = []
    private static let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI, .withoutMounting]
    #endif

    /// A bookmark to a file the user chose, to keep in the project. The
    /// caller has access to the file while this is made.
    public static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The bookmark's file, with access to it, or nil if it can't be found.
    public func url(for bookmark: Data) -> URL? {
        if let resolved = state.withLock({ $0.resolved[bookmark] }) { return resolved.url }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark, options: Self.resolutionOptions, relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        let isAccessing = url.startAccessingSecurityScopedResource()
        let fresh = isStale ? try? Self.bookmark(for: url) : nil

        return state.withLock { state in
            // Resolved meanwhile on another thread: keep the first, and let
            // this access go.
            if let resolved = state.resolved[bookmark] {
                if isAccessing { url.stopAccessingSecurityScopedResource() }
                return resolved.url
            }
            state.resolved[bookmark] = Resolved(url: url, isAccessing: isAccessing)
            if let fresh {
                state.refreshed[bookmark] = fresh
                // The fresh bookmark finds the same file, with the same access.
                state.resolved[fresh] = Resolved(url: url, isAccessing: false)
            }
            return url
        }
    }

    /// Fresh bookmarks made for stale ones, by the stale bookmark, since
    /// they were last taken. Taking them clears them.
    public func takeRefreshedBookmarks() -> [Data: Data] {
        state.withLock { state in
            defer { state.refreshed = [:] }
            return state.refreshed
        }
    }

    /// Forgets a bookmark's file, so it's resolved again next time it's
    /// asked for: as when it was found missing, and may have been put back.
    public func forget(_ bookmark: Data) {
        state.withLock { state in
            if let resolved = state.resolved.removeValue(forKey: bookmark), resolved.isAccessing {
                resolved.url.stopAccessingSecurityScopedResource()
            }
        }
    }
}

extension Project {
    /// Puts fresh bookmarks in place of stale ones. Returns whether any
    /// media's changed.
    @discardableResult
    public mutating func replaceBookmarks(_ fresh: [Data: Data]) -> Bool {
        var changed = false
        for index in media.indices {
            if case .bookmark(let data) = media[index].location, let replacement = fresh[data] {
                media[index].location = .bookmark(replacement)
                changed = true
            }
        }
        return changed
    }
}
