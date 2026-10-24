import Foundation
import MontageEngine
import Synchronization

/// The media of one open project: what's already in its package, and what
/// has been imported since it was last saved.
///
/// Importing copies a file into a staging folder outside the package, and the
/// new media item points at the path it will have inside the package, such as
/// `Media/Clip.mov`. Saving adds the staged files to the package (see
/// `ProjectPackage.fileWrapper(for:existing:media:)`), by reference rather
/// than by reading them into memory. Until then, and whenever the package's
/// copy can't be found, `resolver` finds the staged copy instead.
///
/// The document owns one of these for as long as it's open, and tells it
/// where the package is whenever that changes: when it's first saved, renamed
/// or moved. The staging folder is deleted when the store goes away.
public final class PackageMediaStore: Sendable {
    private struct State {
        var packageURL: URL?
        /// Staged files, by their path in the package.
        var staged: [String: URL] = [:]
    }

    private let state: Mutex<State>
    /// Where imported files wait to be saved into the package.
    public let stagingDirectory: URL
    /// Media left where it was, on the Mac, rather than copied in.
    public let bookmarks = MediaBookmarks()

    public init(packageURL: URL? = nil) {
        state = Mutex(State(packageURL: packageURL))
        stagingDirectory = URL.temporaryDirectory
            .appending(path: "Montage Media \(UUID().uuidString)", directoryHint: .isDirectory)
    }

    deinit {
        try? FileManager.default.removeItem(at: stagingDirectory)
    }

    /// Where the project's package is on disk, once it has been saved.
    public var packageURL: URL? {
        get { state.withLock { $0.packageURL } }
        set { state.withLock { $0.packageURL = newValue } }
    }

    /// Finds the files behind the project's media: in the package if they're
    /// there, or where they were staged if they haven't been saved yet, and
    /// through its bookmark for media left where it was.
    public var resolver: MediaResolver {
        MediaResolver { [self] item in
            switch item.location {
            case .package(let path): url(forPackagePath: path)
            case .bookmark(let data): bookmarks.url(for: data)
            }
        }
    }

    /// The file behind a path in the package.
    public func url(forPackagePath path: String) -> URL? {
        let (packageURL, staged) = state.withLock { ($0.packageURL, $0.staged[path]) }
        if let packageURL {
            let url = packageURL.appending(path: path, directoryHint: .notDirectory)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return staged
    }

    /// The staged file for a path in the package, if there is one.
    public func stagedURL(forPackagePath path: String) -> URL? {
        state.withLock { $0.staged[path] }
    }

    // MARK: - Staging

    /// Copies a file into staging, ready to be saved into the package, and
    /// returns the path it will have there. The copy is a clone where the
    /// file system can make one, so it costs no space until either changes.
    ///
    /// The file keeps its name, made unique against `takenPaths` (the paths of
    /// the project's media), whatever else is staged and whatever is in the
    /// package already.
    public func stage(copying url: URL, takenPaths: Set<String> = []) throws -> String {
        try stage(url, takenPaths: takenPaths) { try FileManager.default.copyItem(at: url, to: $0) }
    }

    /// Moves a file into staging: one this app made for the purpose, such as
    /// a copy received from the photo library.
    public func stage(moving url: URL, takenPaths: Set<String> = []) throws -> String {
        try stage(url, takenPaths: takenPaths) { try FileManager.default.moveItem(at: url, to: $0) }
    }

    /// Throws a staged file away, as when it turns out it can't be used.
    public func discardStaged(_ path: String) {
        guard let url = state.withLock({ $0.staged.removeValue(forKey: path) }) else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private func stage(_ url: URL, takenPaths: Set<String>, transfer: (URL) throws -> Void) throws -> String {
        let fileManager = FileManager.default
        // Each file gets a folder of its own, so it can keep its name in
        // staging whatever name it has in the package.
        let folder = stagingDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: url.lastPathComponent, directoryHint: .notDirectory)
        do {
            try transfer(destination)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }

        return state.withLock { state in
            var taken = takenPaths.union(state.staged.keys)
            if let packageURL = state.packageURL {
                let media = packageURL.appending(path: ProjectPackage.mediaDirectoryName, directoryHint: .isDirectory)
                let names = (try? fileManager.contentsOfDirectory(atPath: media.path)) ?? []
                taken.formUnion(names.map { ProjectPackage.mediaPath(forFileName: $0) })
            }
            let path = ProjectPackage.uniqueMediaPath(for: url.lastPathComponent, avoiding: taken)
            state.staged[path] = destination
            return path
        }
    }
}
