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
    static let formatVersionKey = "formatVersion"

    /// Reads the project out of a package, bringing it up to the current
    /// format if it was saved by an earlier version.
    public static func read(_ package: FileWrapper) throws -> Project {
        guard package.isDirectory else { throw ProjectPackageError.notAPackage }
        guard let data = package.fileWrappers?[projectFileName]?.regularFileContents else {
            throw ProjectPackageError.missingProject
        }
        return try decodeProject(from: data)
    }

    /// Decodes `project.json`. The version is read first: a project from a
    /// later version is refused rather than misread, and one from an earlier
    /// version goes through `migrations` before it's decoded.
    static func decodeProject(
        from data: Data, currentVersion: Int = Project.currentFormatVersion,
        migrations: [ProjectMigration] = ProjectMigration.all
    ) throws -> Project {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? ProjectMigration.JSONObject,
              let version = object[formatVersionKey] as? Int, version >= 1 else {
            throw ProjectPackageError.missingProject
        }
        guard version <= currentVersion else { throw ProjectPackageError.newerFormat }
        guard version < currentVersion else {
            return try JSONDecoder().decode(Project.self, from: data)
        }
        try ProjectMigration.migrate(&object, from: version, to: currentVersion, using: migrations)
        let migrated = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(Project.self, from: migrated)
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
    /// Saved in an earlier format with no way to bring it up to date.
    case missingMigration(from: Int)

    public var errorDescription: String? {
        switch self {
        case .notAPackage, .missingProject, .missingMigration:
            String(localized: "ProjectPackage.Error.Unreadable", bundle: #bundle)
        case .newerFormat:
            String(localized: "ProjectPackage.Error.NewerFormat", bundle: #bundle)
        }
    }
}
