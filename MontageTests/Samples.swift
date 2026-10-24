import Foundation

/// Sample media for tests that need real files, kept outside the repository.
/// Tests that use them are skipped where the folder isn't there.
enum Samples {
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Developer/ClaudeDocs/Samples", directoryHint: .isDirectory)

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: directory.path)
    }

    static func url(_ name: String) -> URL {
        directory.appending(path: name)
    }
}
