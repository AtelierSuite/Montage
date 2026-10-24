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
    ///
    /// Media imported since the last save is added from `media`'s staging
    /// folder, as file wrappers that point at the staged files, so even a
    /// long video isn't read into memory to be saved. Only media the project
    /// still uses is added: an import that was undone isn't saved.
    ///
    /// Media the project no longer uses stays in the package, so that undoing
    /// its removal still finds it, unless `removingUnusedMedia` is set.
    public static func fileWrapper(
        for project: Project, existing: FileWrapper?, media: PackageMediaStore? = nil,
        removingUnusedMedia: Bool = false
    ) throws -> FileWrapper {
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

        try addStagedMedia(for: project, from: media, to: package)
        if removingUnusedMedia {
            removeUnusedMedia(from: package, for: project)
        }
        addCache(to: package, packageURL: media?.packageURL)
        return package
    }

    private static func addStagedMedia(for project: Project, from media: PackageMediaStore?, to package: FileWrapper) throws {
        let directory = subdirectory(mediaDirectoryName, of: package)
        guard let media else { return }
        for path in project.packageMediaPaths {
            guard let name = fileName(inMediaPath: path), directory.fileWrappers?[name] == nil,
                  let staged = media.stagedURL(forPackagePath: path) else { continue }
            // Read lazily: the file is copied when the package is written.
            let file = try FileWrapper(url: staged, options: [])
            file.preferredFilename = name
            directory.addFileWrapper(file)
        }
    }

    /// Keeps the package's cache folder. Its contents are written straight
    /// into the package on disk as they're made, between saves, so the folder
    /// on disk is newer than any copy of it read when the project was opened.
    private static func addCache(to package: FileWrapper, packageURL: URL?) {
        if let packageURL,
           let onDisk = try? FileWrapper(url: cacheDirectory(inPackageAt: packageURL), options: []),
           onDisk.isDirectory {
            if let old = package.fileWrappers?[cacheDirectoryName] {
                package.removeFileWrapper(old)
            }
            onDisk.preferredFilename = cacheDirectoryName
            package.addFileWrapper(onDisk)
        } else {
            _ = subdirectory(cacheDirectoryName, of: package)
        }
    }

    /// A folder in the package, made if it isn't there.
    private static func subdirectory(_ name: String, of package: FileWrapper) -> FileWrapper {
        if let directory = package.fileWrappers?[name], directory.isDirectory {
            return directory
        }
        if let file = package.fileWrappers?[name] {
            package.removeFileWrapper(file)
        }
        let directory = FileWrapper(directoryWithFileWrappers: [:])
        directory.preferredFilename = name
        package.addFileWrapper(directory)
        return directory
    }

    // MARK: - Media

    /// The folder imported media is copied into.
    public static let mediaDirectoryName = "Media"

    /// The path in the package of a file in the media folder.
    public static func mediaPath(forFileName name: String) -> String {
        "\(mediaDirectoryName)/\(name)"
    }

    static func fileName(inMediaPath path: String) -> String? {
        let prefix = mediaDirectoryName + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let name = String(path.dropFirst(prefix.count))
        return name.isEmpty || name.contains("/") ? nil : name
    }

    /// A path in the media folder for a file of this name that isn't one of
    /// `taken`: the name as it is, or with a number added before the
    /// extension, "Clip 2.mov". Names are compared ignoring case, as most
    /// file systems do.
    public static func uniqueMediaPath(for fileName: String, avoiding taken: Set<String>) -> String {
        let taken = Set(taken.map { $0.lowercased() })
        // A name from elsewhere can't be allowed to reach out of the folder.
        var name = fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        if name.isEmpty || name.hasPrefix(".") { name = "Media" + name }
        let base = (name as NSString).deletingPathExtension
        let pathExtension = (name as NSString).pathExtension
        var candidate = name
        var number = 2
        while taken.contains(mediaPath(forFileName: candidate).lowercased()) {
            candidate = pathExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(pathExtension)"
            number += 1
        }
        return mediaPath(forFileName: candidate)
    }

    /// The files in a package's media folder that no media item points at:
    /// left behind when media is removed from the library. They're kept, in
    /// case the removal is undone, until `removeUnusedMedia` is called.
    public static func unusedMediaPaths(in package: FileWrapper, for project: Project) -> [String] {
        guard let names = package.fileWrappers?[mediaDirectoryName]?.fileWrappers?.keys else { return [] }
        let used = project.packageMediaPaths
        return names.map(mediaPath(forFileName:)).filter { !used.contains($0) }.sorted()
    }

    /// Takes the files no media item points at out of a package, so the next
    /// time it's written they're gone. Returns their paths.
    @discardableResult
    public static func removeUnusedMedia(from package: FileWrapper, for project: Project) -> [String] {
        let unused = unusedMediaPaths(in: package, for: project)
        guard let directory = package.fileWrappers?[mediaDirectoryName] else { return [] }
        for path in unused {
            if let name = fileName(inMediaPath: path), let file = directory.fileWrappers?[name] {
                directory.removeFileWrapper(file)
            }
        }
        return unused
    }

    // MARK: - Cache

    /// The folder for thumbnails, waveforms and proxies. Everything in it can
    /// be made again from the media, so it may be deleted at any time, and
    /// whatever reads from it makes what's missing.
    public static let cacheDirectoryName = "Cache"

    /// The cache folder of a package on disk. It may not be there yet.
    public static func cacheDirectory(inPackageAt packageURL: URL) -> URL {
        packageURL.appending(path: cacheDirectoryName, directoryHint: .isDirectory)
    }
}

extension Project {
    /// The paths of the media kept in the project's package: the paths a
    /// new import's file mustn't take.
    public var packageMediaPaths: Set<String> {
        Set(media.compactMap { item in
            if case .package(let path) = item.location { path } else { nil }
        })
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
