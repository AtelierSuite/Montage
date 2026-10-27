import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// LumaFusion's project package: a ZIP archive of the project and the
    /// media it uses. LumaFusion's guide calls it `.lfpackage`, and `.lfz`
    /// is accepted as well, as is `.spryzip`, which LumaFusion for iOS used
    /// for the same package before 2020. LumaFusion publishes no type of its
    /// own.
    public static let lumaFusionPackage = UTType(importedAs: "com.luma-touch.lumafusion.package", conformingTo: .zip)
}

/// A LumaFusion project package, read where it is: its project file is read
/// from the archive, and the media its project uses unpacked from there
/// straight into staging, so a package of several gigabytes is never
/// unpacked whole.
///
/// As real packages from LumaFusion for Android 2.6 are laid out: a ZIP
/// archive, ZIP64 past 4 GB, holding a single `*.lfarchive` file, the
/// project as JSON, with the media beside it at the top, deflated. An
/// open-source reader describes packages from LumaFusion for iOS 5.5 the
/// same way, with the media stored uncompressed, as a real package from
/// LumaFusion for iOS 3.1 is. Packages from LumaFusion for iOS 3.0.9 and
/// earlier hold a keyed archive, `*.spryArchive`, in place of the JSON,
/// with names in UTF-8 not flagged as such and the same file listed more
/// than once; they're recognised, and refused. Other versions may use
/// folders, so media is looked for by name wherever it is in the archive.
struct LumaFusionPackage {
    static let fileExtensions = ["lfpackage", "lfz", "spryzip"]
    static let projectFileExtension = "lfarchive"
    /// The project file of LumaFusion for iOS 3.0.9 and earlier: a keyed
    /// archive, which isn't read.
    static let keyedArchiveExtension = "spryarchive"

    private let archive: ZipArchive
    /// The package's files, each path once, as the archive lists them. Those
    /// whose path would climb out of the package, and the resource forks
    /// Finder adds, are passed over.
    let files: [ZipArchive.Entry]
    /// The project file, if the package has one.
    let projectFile: ZipArchive.Entry?
    /// The project file of an older version of LumaFusion, if the package
    /// has one.
    let keyedArchiveFile: ZipArchive.Entry?
    /// An FCPXML document, if the package has one beside or instead of the
    /// project file, as LumaFusion's own FCPXML export, zipped, does.
    let fcpxmlFile: ZipArchive.Entry?

    /// Opens the package at `url`, reading no more than its list of files.
    init(reading url: URL) throws {
        do {
            archive = try ZipArchive(url: url)
        } catch let error as ZipArchive.Error {
            throw error == .notAnArchive ? LumaFusionError.notAPackage : LumaFusionError.damaged
        }
        var seen: Set<String> = []
        let files = archive.entries.filter { entry in
            guard !entry.isDirectory, let components = ZipArchive.safeComponents(of: entry.path),
                  components.first != "__MACOSX", components.last?.hasPrefix("._") == false else { return false }
            return seen.insert(components.joined(separator: "/")).inserted
        }
        self.files = files
        func shallowest(withExtension pathExtension: String) -> ZipArchive.Entry? {
            Self.shallowest(files.filter { ($0.fileName as NSString).pathExtension.lowercased() == pathExtension })
        }
        projectFile = shallowest(withExtension: Self.projectFileExtension)
        keyedArchiveFile = shallowest(withExtension: Self.keyedArchiveExtension)
        fcpxmlFile = shallowest(withExtension: "fcpxml")
    }

    /// The folder the package is in.
    var folder: URL { archive.url.deletingLastPathComponent() }

    /// A file's contents, refused as damaged when they'd be larger than
    /// `limit`.
    func data(of file: ZipArchive.Entry, limit: Int) throws -> Data {
        do {
            return try archive.data(for: file, limit: limit)
        } catch is ZipArchive.Error {
            throw LumaFusionError.damaged
        }
    }

    /// The file at a path in the package, as folder and file names.
    func file(at components: [String]) -> ZipArchive.Entry? {
        files.first { ZipArchive.safeComponents(of: $0.path) == components }
    }

    /// The file called one of `names`, exactly, wherever it is in the
    /// package: the one in the shallowest folder, the first listed of those.
    func file(namedAnyOf names: [String]) -> ZipArchive.Entry? {
        Self.shallowest(files.filter { names.contains($0.fileName) })
    }

    /// Unpacks a file straight into staging, under its own name, and
    /// returns the path it will have in the project's package.
    func stage(_ file: ZipArchive.Entry, into store: PackageMediaStore, takenPaths: Set<String>) throws -> String {
        do {
            return try store.stage(named: file.fileName, takenPaths: takenPaths) { try archive.extract(file, to: $0) }
        } catch is ZipArchive.Error {
            throw LumaFusionError.damaged
        }
    }

    /// Whether a file is a LumaFusion package: by its type or extension, or,
    /// failing those, by being a ZIP archive with a LumaFusion project file,
    /// of any version, in it. Other formats are ZIP archives too, so being
    /// one isn't enough.
    static func isPackage(_ url: URL) -> Bool {
        if fileExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .lumaFusionPackage) { return true }
        guard !url.hasDirectoryPath, let archive = try? ZipArchive(url: url) else { return false }
        return archive.entries.contains {
            !$0.isDirectory && [projectFileExtension, keyedArchiveExtension]
                .contains(($0.fileName as NSString).pathExtension.lowercased())
        }
    }

    private static func shallowest(_ files: [ZipArchive.Entry]) -> ZipArchive.Entry? {
        files.min { ($0.path.split(separator: "/").count) < ($1.path.split(separator: "/").count) }
    }
}
