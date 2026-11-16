import Foundation
import Synchronization

/// Brings files kept in iCloud down to the device.
///
/// A package opened from iCloud Drive is read for its project, but the files
/// in it come down on their own, each when it's asked for: until then, each
/// is a placeholder, `.Clip.mov.icloud` beside where the file will be, or a
/// file with no data in it yet. Coordinating a read of the package doesn't
/// bring down what's inside it, so each file is asked for by itself.
public enum UbiquitousDownload {
    /// Whether the file at `url` is in iCloud and not on the device yet.
    public static func isPending(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values?.isUbiquitousItem == true {
            return values?.ubiquitousItemDownloadingStatus != .current
        }
        // Not known to iCloud by its own name: a placeholder may stand in for it.
        let fileManager = FileManager.default
        return !fileManager.fileExists(atPath: url.path) && fileManager.fileExists(atPath: placeholderURL(for: url).path)
    }

    /// Downloads the files at `urls` that aren't on the device yet, all at
    /// once, and gives each URL as its file arrives, in whatever order they
    /// do. Ends once each has arrived or failed to; files that were already
    /// there aren't given.
    public static func download(_ urls: [URL]) -> AsyncStream<URL> {
        let pending = urls.filter(isPending)
        return AsyncStream { continuation in
            guard !pending.isEmpty else {
                continuation.finish()
                return
            }
            let queue = OperationQueue()
            queue.name = "UbiquitousDownload"
            let downloads = Downloads(count: pending.count)
            for url in pending {
                try? FileManager.default.startDownloadingUbiquitousItem(at: url)
                // A coordinated read of a file waits for it to be downloaded.
                // Without changes, so the open document isn't asked to save
                // first.
                let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
                downloads.coordinator.coordinate(with: [intent], queue: queue) { error in
                    if error == nil { continuation.yield(url) }
                    if downloads.finishOne() { continuation.finish() }
                }
            }
            continuation.onTermination = { _ in downloads.coordinator.cancel() }
        }
    }

    /// Where iCloud keeps the placeholder for a file not downloaded yet.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).icloud", directoryHint: .notDirectory)
    }

    /// The reads waiting for files to arrive, and how many are left.
    /// Unchecked: a coordinator may be cancelled from any thread.
    private final class Downloads: @unchecked Sendable {
        let coordinator = NSFileCoordinator()
        private let remaining: Mutex<Int>

        init(count: Int) { remaining = Mutex(count) }

        /// Counts one read done; true for the last.
        func finishOne() -> Bool {
            remaining.withLock {
                $0 -= 1
                return $0 == 0
            }
        }
    }
}
