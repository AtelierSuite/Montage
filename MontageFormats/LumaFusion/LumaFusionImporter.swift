import Foundation
import MontageEngine

/// Why a LumaFusion package couldn't be imported.
public enum LumaFusionError: LocalizedError, Equatable {
    /// Not a ZIP archive at all.
    case notAPackage
    /// A ZIP archive that's damaged or cut short.
    case damaged
    /// An archive with no LumaFusion project in it.
    case noProject
    /// A project saved by a version of LumaFusion Montage hasn't been tested
    /// with, named where the project says.
    case unsupportedVersion(String?)
    /// A project saved by LumaFusion for iOS 3.0.9 or earlier, as a keyed
    /// archive (`*.spryArchive`) rather than JSON, which Montage can't read.
    case olderVersion

    public var errorDescription: String? {
        switch self {
        case .notAPackage:
            String(localized: "LumaFusion.Error.NotAPackage", bundle: #bundle)
        case .damaged:
            String(localized: "LumaFusion.Error.Damaged", bundle: #bundle)
        case .noProject:
            String(localized: "LumaFusion.Error.NoProject", bundle: #bundle)
        case .unsupportedVersion(let version?):
            String(format: String(localized: "LumaFusion.Error.UnsupportedVersion", bundle: #bundle), version)
        case .unsupportedVersion(nil):
            String(localized: "LumaFusion.Error.UnsupportedVersionUnknown", bundle: #bundle)
        case .olderVersion:
            String(localized: "LumaFusion.Error.OlderVersion", bundle: #bundle)
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noProject, .unsupportedVersion: String(localized: "LumaFusion.Error.ExportFCPXML", bundle: #bundle)
        case .olderVersion: String(localized: "LumaFusion.Error.SaveAgain", bundle: #bundle)
        case .notAPackage, .damaged: nil
        }
    }
}

/// The project file inside a LumaFusion package, as far as it's known: JSON,
/// with the version of LumaFusion that saved it at `attributes.appVersion`.
struct LumaFusionProjectFile: Sendable {
    let data: Data
    /// The version of LumaFusion that saved the project, such as "5.5.2".
    let appVersion: String?
    let title: String?

    init(data: Data) throws {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LumaFusionError.damaged
        }
        self.data = data
        let attributes = root["attributes"] as? [String: Any]
        appVersion = (attributes?["appVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        title = root["title"] as? String
    }
}

/// Turns a LumaFusion project file into an imported project, for the
/// versions of LumaFusion it's been tested against.
protocol LumaFusionProjectDecoder: Sendable {
    /// Whether projects saved by this version of LumaFusion have been tested.
    func supports(appVersion: String) -> Bool
    /// The project, its media's sources being files in `package`, to be
    /// gathered from there.
    func decode(_ file: LumaFusionProjectFile, in package: LumaFusionPackage) throws -> ImportedProject
}

/// Reads LumaFusion project packages.
///
/// A package that carries an FCPXML document, as LumaFusion's zipped FCPXML
/// export does, is read from that, through the FCPXML importer. Otherwise
/// its own project file is read, by the decoder for the version of
/// LumaFusion that saved it, onto the same intermediate project as FCPXML,
/// sharing the import report and media gathering. A project file no decoder
/// can read is refused with a message pointing to LumaFusion's FCPXML
/// export.
enum LumaFusionImporter {
    /// The decoders, one for each layout of LumaFusion's project file.
    static let decoders: [any LumaFusionProjectDecoder] = [LumaFusionNativeDecoder()]

    /// Largest project file read: a project's JSON, not its media.
    static let projectFileLimit = 256 * 1024 * 1024

    /// Reads a package's project. Media an FCPXML document in it refers to
    /// by relative paths is taken to be beside the package, where it's
    /// looked for in the package as well.
    static func read(_ package: LumaFusionPackage, decoders: [any LumaFusionProjectDecoder] = decoders) throws -> ImportedProject {
        if let fcpxml = package.fcpxmlFile {
            return try ProjectInterchange.read(try package.data(of: fcpxml, limit: projectFileLimit), baseURL: package.folder)
        }
        guard let entry = package.projectFile else {
            throw package.keyedArchiveFile == nil ? LumaFusionError.noProject : LumaFusionError.olderVersion
        }
        let data = try package.data(of: entry, limit: projectFileLimit)
        // A keyed archive under the JSON project's name.
        if data.starts(with: Data("bplist".utf8)) { throw LumaFusionError.olderVersion }
        let file = try LumaFusionProjectFile(data: data)
        guard let version = file.appVersion, let decoder = decoders.first(where: { $0.supports(appVersion: version) }) else {
            throw LumaFusionError.unsupportedVersion(file.appVersion)
        }
        return try decoder.decode(file, in: package)
    }

    /// Unpacks the files the project's media are in that the package
    /// carries straight into staging, and returns the path each will have
    /// in the project's package. Each is looked for where the project said,
    /// when that's inside the package, then by name anywhere in it. If any
    /// can't be unpacked, none stay staged.
    static func stageMedia(
        for imported: ImportedProject, from package: LumaFusionPackage, into store: PackageMediaStore,
        takenPaths: Set<String> = []
    ) throws -> [MediaItem.ID: String] {
        var staged: [MediaItem.ID: String] = [:]
        do {
            for item in imported.project.media {
                let source = imported.mediaSources[item.id]
                let names = [item.name, source?.lastPathComponent].compactMap { $0 }.filter { !$0.isEmpty }
                guard let file = source.flatMap({ relativePath(of: $0, in: package) }).flatMap(package.file(at:))
                    ?? package.file(namedAnyOf: names) else { continue }
                staged[item.id] = try package.stage(file, into: store, takenPaths: takenPaths)
            }
        } catch {
            for path in staged.values { store.discardStaged(path) }
            throw error
        }
        return staged
    }

    /// A file's path from beside the package, as folder and file names; nil
    /// for one elsewhere.
    private static func relativePath(of url: URL, in package: LumaFusionPackage) -> [String]? {
        guard url.isFileURL, let folder = package.folder?.standardizedFileURL.pathComponents else { return nil }
        let components = url.standardizedFileURL.pathComponents
        guard components.count > folder.count, Array(components.prefix(folder.count)) == folder else { return nil }
        return Array(components.dropFirst(folder.count))
    }
}

extension ProjectInterchange {
    /// Whether a file is a LumaFusion project package, to be imported with
    /// `importLumaFusionPackage` rather than `read`.
    public static func isLumaFusionPackage(_ url: URL) -> Bool {
        LumaFusionPackage.isPackage(url)
    }

    /// Imports a LumaFusion project package: reads its project, and copies
    /// the media it carries into staging, unpacked straight there, then
    /// looks for the rest as `gatherMedia` does, beside the package.
    @concurrent
    public static func importLumaFusionPackage(
        at url: URL, into store: PackageMediaStore, takenPaths: Set<String> = []
    ) async throws -> ImportedProject {
        let (imported, staged) = try coordinatedRead(url) { readURL in
            let package = try LumaFusionPackage(reading: readURL)
            let imported = try LumaFusionImporter.read(package)
            return (imported, try LumaFusionImporter.stageMedia(for: imported, from: package, into: store, takenPaths: takenPaths))
        }
        return await gatherMedia(
            for: imported, into: store, takenPaths: takenPaths, searchFolders: [url.deletingLastPathComponent()], staged: staged
        )
    }

    /// Reads the package, coordinated, so a package in cloud storage that
    /// isn't on the device yet is downloaded first.
    private static func coordinatedRead<Value>(_ url: URL, _ read: (URL) throws -> Value) throws -> Value {
        var coordinationError: NSError?
        var result: Result<Value, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try read(readURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
