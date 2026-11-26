import Foundation

/// Sample media for tests that need real files, kept outside the repository.
/// Tests that use them are skipped where the folder isn't there.
enum Samples {
    static let directory = URL(fileURLWithPath: NSHomeDirectory())
        .appending(path: "Developer/ClaudeDocs/Samples", directoryHint: .isDirectory)

    /// Real project files from other editors, one folder per format.
    static let interchange = directory.appending(path: "Interchange", directoryHint: .isDirectory)

    /// Whether the sample media is there, not just the interchange corpus.
    static var isAvailable: Bool {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return contents.contains { $0 != "Interchange" && !$0.hasPrefix(".") }
    }

    static var isInterchangeAvailable: Bool {
        FileManager.default.fileExists(atPath: interchange.path)
    }

    static func url(_ name: String) -> URL {
        directory.appending(path: name)
    }
}
