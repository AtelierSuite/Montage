import MontageEngine
import MontageFormats
import SwiftUI
import UniformTypeIdentifiers

/// The app's document: a project package, as a SwiftUI document.
struct MontageDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.montageProject]

    var project: Project

    init() {
        project = Project()
    }

    init(configuration: ReadConfiguration) throws {
        project = try ProjectPackage.read(configuration.file)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try ProjectPackage.fileWrapper(for: project, existing: configuration.existingFile)
    }
}
