import Foundation
import MontageEngine
import MontageFormats

/// Bringing in the files found for missing media, the way imports are.
extension MediaImporter {
    /// Points missing media at the files the user confirmed, as one undo
    /// step. Each file is copied into the project, as an import is, or on the
    /// Mac left where it is if the item was before or that's what's
    /// preferred. Returns the files that couldn't be brought in.
    func relink(_ matches: [MediaRelinker.Match], in editor: ProjectEditor) async -> [Failure] {
        var relinks: [MediaItem.ID: (location: MediaLocation, metadata: MediaMetadata)] = [:]
        var failures: [Failure] = []
        var taken = editor.project.packageMediaPaths
        for match in matches {
            guard let item = editor.project.mediaItem(id: match.mediaID) else { continue }
            do {
                let location = try await Self.location(for: match.url, replacing: item, store: store, takenPaths: taken)
                if case .package(let path) = location { taken.insert(path) }
                relinks[item.id] = (location, match.probed.metadata)
            } catch {
                failures.append(Failure(name: match.url.lastPathComponent, message: Self.message(for: error)))
            }
        }
        await editor.relinkMedia(relinks)
        return failures
    }

    @concurrent
    private nonisolated static func location(
        for url: URL, replacing item: MediaItem, store: PackageMediaStore, takenPaths: Set<String>
    ) async throws -> MediaLocation {
        #if os(macOS)
        let wasReferenced = if case .bookmark = item.location { true } else { false }
        if wasReferenced || referencesFilesInPlace {
            let isAccessing = url.startAccessingSecurityScopedResource()
            defer { if isAccessing { url.stopAccessingSecurityScopedResource() } }
            return .bookmark(try MediaBookmarks.bookmark(for: url))
        }
        #endif
        return .package(path: try stageCoordinated(url, store: store, takenPaths: takenPaths))
    }
}
