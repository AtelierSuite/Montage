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
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noProject, .unsupportedVersion: String(localized: "LumaFusion.Error.ExportFCPXML", bundle: #bundle)
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

    /// Reads an unpacked package's project.
    static func read(_ package: LumaFusionPackage, decoders: [any LumaFusionProjectDecoder] = decoders) throws -> ImportedProject {
        if let fcpxml = package.fcpxmlFile {
            return try ProjectInterchange.read(contentsOf: fcpxml)
        }
        guard let url = package.projectFile else { throw LumaFusionError.noProject }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= projectFileLimit else { throw LumaFusionError.damaged }
        let file = try LumaFusionProjectFile(data: Data(contentsOf: url))
        guard let version = file.appVersion, let decoder = decoders.first(where: { $0.supports(appVersion: version) }) else {
            throw LumaFusionError.unsupportedVersion(file.appVersion)
        }
        return try decoder.decode(file, in: package)
    }
}

extension ProjectInterchange {
    /// Whether a file is a LumaFusion project package, to be imported with
    /// `importLumaFusionPackage` rather than `read`.
    public static func isLumaFusionPackage(_ url: URL) -> Bool {
        LumaFusionPackage.isPackage(url)
    }

    /// Imports a LumaFusion project package: unpacks it, reads its project,
    /// and copies the media it carries into staging, as `gatherMedia` does,
    /// looking in the package first and then beside it. The project is read
    /// before the media is unpacked, so one that can't be read is refused
    /// without unpacking it.
    @concurrent
    public static func importLumaFusionPackage(
        at url: URL, into store: PackageMediaStore, takenPaths: Set<String> = []
    ) async throws -> ImportedProject {
        let folder = URL.temporaryDirectory.appending(path: "LumaFusion-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let (package, imported) = try coordinatedUnpack(url, into: folder)
        return await gatherMedia(
            for: imported, into: store, takenPaths: takenPaths,
            searchFolders: package.mediaFolders + [url.deletingLastPathComponent()]
        )
    }

    /// Reads the package's project and then unpacks its media, coordinated,
    /// so a package in cloud storage that isn't on the device yet is
    /// downloaded first.
    private static func coordinatedUnpack(
        _ url: URL, into folder: URL
    ) throws -> (package: LumaFusionPackage, imported: ImportedProject) {
        var coordinationError: NSError?
        var result: Result<(LumaFusionPackage, ImportedProject), Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result {
                var package = try LumaFusionPackage(opening: readURL, into: folder)
                let imported = try LumaFusionImporter.read(package)
                try package.unpackMedia()
                return (package, imported)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
