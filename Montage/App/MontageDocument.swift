import MontageEngine
import MontageFormats
import SwiftUI
import UniformTypeIdentifiers

/// The app's document: a project package, as a SwiftUI document.
struct MontageDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.montageProject]

    var project: Project
    /// The media imported into the project but not saved yet, and where the
    /// package is. A reference, so every copy SwiftUI makes of the document
    /// shares it: the copy that's written sees what the editor imported.
    let media: PackageMediaStore
    /// Thumbnails and waveforms, kept in the package's cache folder; shared
    /// by every copy the same way.
    let cache: PackageCache

    init() {
        project = Project()
        media = PackageMediaStore()
        cache = PackageCache()
    }

    init(configuration: ReadConfiguration) throws {
        project = try ProjectPackage.read(configuration.file)
        media = PackageMediaStore()
        cache = PackageCache()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Staged media goes into the package by reference to its staged
        // file, so saving a long video doesn't read it into memory.
        try ProjectPackage.fileWrapper(for: project, existing: configuration.existingFile, media: media)
    }
}
