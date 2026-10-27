import CoreGraphics
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// Finds files for media whose own have gone: moved, renamed, on a drive
/// that isn't connected, or never on this device at all, as with a project
/// brought in from another editor. Shared by everything that can leave media
/// missing, whatever format the project came from.
///
/// Files are matched by name first: the same file name, ignoring case, or
/// failing that the same name with another extension, as when a clip was
/// transcoded. Each match is then checked against what the media was like
/// when it was imported (its kind, duration, frame rate and size) so the
/// user can see which files are surely the same media and which only share
/// a name.
public enum MediaRelinker {
    /// A file found for a missing media item.
    public struct Match: Equatable, Sendable {
        public var mediaID: MediaItem.ID
        public var url: URL
        /// What the file is like, to relink the item with.
        public var probed: ProbedMedia
        /// How it differs from the media as imported. Empty when it's the
        /// same in every way that was checked.
        public var differences: [Difference]

        /// Whether the file is surely the same media.
        public var isConfirmed: Bool { differences.isEmpty }
    }

    /// A way a file differs from the media it's meant to stand in for.
    public enum Difference: Equatable, Sendable {
        case kind(expected: MediaItem.Kind, found: MediaItem.Kind)
        case duration(expected: CMTime, found: CMTime)
        case frameRate(expected: Double, found: Double)
        case size(expected: CGSize, found: CGSize)
    }

    /// The kinds of file worth looking at.
    static let mediaTypes: [UTType] = [.movie, .audio, .image]

    /// Every media file in a folder and the folders in it, leaving out hidden
    /// files and packages, such as other projects.
    public static func mediaFiles(in folder: URL) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentTypeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let type = values.contentType else { return false }
            return mediaTypes.contains { type.conforms(to: $0) }
        }
    }

    /// The files whose names could be the item's, best first: the same file
    /// name, ignoring case, then the same name with another extension.
    public static func candidates(for item: MediaItem, among files: [URL]) -> [URL] {
        let name = item.name.lowercased()
        let base = (name as NSString).deletingPathExtension
        let exact = files.filter { $0.lastPathComponent.lowercased() == name }
        let sameBase = files.filter { url in
            let fileName = url.lastPathComponent.lowercased()
            return fileName != name && (fileName as NSString).deletingPathExtension == base
        }
        return exact + sameBase
    }

    /// How a file differs from the media as it was imported.
    public static func differences(between item: MediaItem, and probed: ProbedMedia) -> [Difference] {
        guard probed.kind == item.kind else { return [.kind(expected: item.kind, found: probed.kind)] }
        var differences: [Difference] = []
        let expected = item.metadata, found = probed.metadata
        // Media from an edit decision list was never seen: its length and
        // size are stand-ins, not to be held against the file.
        let isStandIn = item.sourceTimecode != nil
        if item.kind != .image, !isStandIn, expected.duration.isNumeric, found.duration.isNumeric {
            // Within a frame or so: containers round durations differently.
            let tolerance = expected.nominalFrameRate > 0 ? max(1.5 / expected.nominalFrameRate, 0.05) : 0.05
            if abs(expected.duration.seconds - found.duration.seconds) > tolerance {
                differences.append(.duration(expected: expected.duration, found: found.duration))
            }
        }
        if expected.nominalFrameRate > 0, abs(expected.nominalFrameRate - found.nominalFrameRate) > expected.nominalFrameRate * 0.005 {
            differences.append(.frameRate(expected: expected.nominalFrameRate, found: found.nominalFrameRate))
        }
        if expected.hasVideo, !isStandIn, expected.presentationSize != found.presentationSize {
            differences.append(.size(expected: expected.presentationSize, found: found.presentationSize))
        }
        return differences
    }

    /// The best file among `files` for each item, if any has a name that
    /// could be its: the first whose media matches in every way, else the
    /// first that can be read at all, with how it differs. Each file is
    /// given to one item at most, and to an item it's surely the media of
    /// before any it only shares a name with.
    @concurrent
    public static func match(_ items: [MediaItem], among files: [URL]) async -> [Match] {
        // Each item's candidates, read once however many items they're named for.
        var probes: [URL: ProbedMedia] = [:]
        var checked: [[Match]] = []
        reading: for item in items {
            var matches: [Match] = []
            for url in candidates(for: item, among: files) {
                guard !Task.isCancelled else { break reading }
                if probes[url] == nil { probes[url] = try? await MediaProbe.probe(url) }
                guard let probed = probes[url] else { continue }
                matches.append(Match(mediaID: item.id, url: url, probed: probed,
                                     differences: differences(between: item, and: probed)))
            }
            checked.append(matches)
        }

        var best = [Match?](repeating: nil, count: checked.count)
        var taken = Set<URL>()
        for confirmedOnly in [true, false] {
            for (index, matches) in checked.enumerated() where best[index] == nil {
                guard let match = matches.first(where: { !taken.contains($0.url) && (!confirmedOnly || $0.isConfirmed) })
                else { continue }
                best[index] = match
                taken.insert(match.url)
            }
        }
        return best.compactMap { $0 }
    }

    /// Checks one file the user picked for an item, whatever its name.
    @concurrent
    public static func check(_ url: URL, for item: MediaItem) async throws -> Match {
        let probed = try await MediaProbe.probe(url)
        return Match(mediaID: item.id, url: url, probed: probed, differences: differences(between: item, and: probed))
    }
}
