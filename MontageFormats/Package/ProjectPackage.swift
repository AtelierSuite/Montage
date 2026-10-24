import Foundation
import MontageEngine
import UniformTypeIdentifiers

extension UTType {
    /// A Montage project: a package, so Files and Finder show it as one file.
    public static let montageProject = UTType(exportedAs: "com.tsubuzaki.Montage.project", conformingTo: .package)
}

/// A project as saved on disk: a package holding the project itself beside
/// the media imported into it.
///
///     MyProject.montage/
///     ├── project.json    the project model, versioned
///     ├── Media/          media imported into the project
///     └── Cache/          thumbnails, waveforms and proxies, made again when missing
public enum ProjectPackage {
    static let projectFileName = "project.json"

    /// Reads the project out of a package.
    public static func read(_ package: FileWrapper) throws -> Project {
        guard package.isDirectory else { throw ProjectPackageError.notAPackage }
        guard let data = package.fileWrappers?[projectFileName]?.regularFileContents else {
            throw ProjectPackageError.missingProject
        }
        let project = try JSONDecoder().decode(Project.self, from: data)
        guard project.formatVersion <= Project.currentFormatVersion else {
            throw ProjectPackageError.newerFormat
        }
        return project
    }

    /// Writes the project into a package. Given the package as it is on disk,
    /// only the project is replaced: media and caches are left where they
    /// are, rather than being written out again on every save.
    public static func fileWrapper(for project: Project, existing: FileWrapper?) throws -> FileWrapper {
        let encoder = JSONEncoder()
        // Sorted and indented, so a project's changes read as a diff.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)

        let package = existing.flatMap { $0.isDirectory ? $0 : nil } ?? FileWrapper(directoryWithFileWrappers: [:])
        if let old = package.fileWrappers?[projectFileName] {
            package.removeFileWrapper(old)
        }
        let file = FileWrapper(regularFileWithContents: data)
        file.preferredFilename = projectFileName
        package.addFileWrapper(file)
        return package
    }
}

public enum ProjectPackageError: LocalizedError {
    case notAPackage
    case missingProject
    /// Saved by a later version of Montage, in a format this one can't read.
    case newerFormat

    public var errorDescription: String? {
        switch self {
        case .notAPackage, .missingProject:
            String(localized: "ProjectPackage.Error.Unreadable", bundle: #bundle)
        case .newerFormat:
            String(localized: "ProjectPackage.Error.NewerFormat", bundle: #bundle)
        }
    }
}
