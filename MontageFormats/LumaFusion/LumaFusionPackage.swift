import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// LumaFusion's project package: a ZIP archive of the project and the
    /// media it uses. LumaFusion's guide calls it `.lfpackage`, and `.lfz`
    /// is accepted as well. LumaFusion publishes no type of its own.
    public static let lumaFusionPackage = UTType(importedAs: "com.luma-touch.lumafusion.package", conformingTo: .zip)
}

/// A LumaFusion project package, unpacked into a folder.
///
/// As real packages from LumaFusion for Android 2.6 are laid out: a ZIP
/// archive, ZIP64 past 4 GB, holding a single `*.lfarchive` file, the
/// project as JSON, with the media beside it at the top, deflated. An
/// open-source reader describes packages from LumaFusion for iOS 5.5 the
/// same way, with the media stored uncompressed. Other versions may use
/// folders, so media is looked for by name wherever it is in the archive.
struct LumaFusionPackage {
    static let fileExtensions = ["lfpackage", "lfz"]
    static let projectFileExtension = "lfarchive"

    /// The folder the package was unpacked into.
    let folder: URL
    /// The project file, if the package has one.
    let projectFile: URL?
    /// An FCPXML document, if the package has one beside or instead of the
    /// project file, as LumaFusion's own FCPXML export, zipped, does.
    let fcpxmlFile: URL?
    /// Every file unpacked.
    private(set) var files: [URL]
    private let archive: ZipArchive
    private let unpacked: Set<String>

    /// Unpacks the package at `url` into `folder`, which is made if need be.
    init(unpacking url: URL, into folder: URL) throws {
        try self.init(opening: url, into: folder)
        try unpackMedia()
    }

    /// Unpacks only the package's project file and FCPXML document, so the
    /// project can be checked before its media, which may be gigabytes, is
    /// unpacked with `unpackMedia`.
    init(opening url: URL, into folder: URL) throws {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch let error as ZipArchive.Error {
            throw error == .notAnArchive ? LumaFusionError.notAPackage : LumaFusionError.damaged
        }
        self.archive = archive
        func shallowest(_ fileExtension: String) -> ZipArchive.Entry? {
            archive.entries.compactMap { entry in
                ZipArchive.unpackedComponents(of: entry).map { (entry, $0) }
            }
            .filter { ($0.1.last.map { ($0 as NSString).pathExtension.lowercased() }) == fileExtension }
            .min { $0.1.count < $1.1.count }?.0
        }
        let project = shallowest(Self.projectFileExtension)
        let fcpxml = shallowest("fcpxml")
        let unpacked = Set([project, fcpxml].compactMap { $0?.path })
        self.unpacked = unpacked
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            files = try archive.extractAll(into: folder) { unpacked.contains($0.path) }
        } catch is ZipArchive.Error {
            throw LumaFusionError.damaged
        }
        self.folder = folder
        func file(for entry: ZipArchive.Entry?) -> URL? {
            entry.flatMap(ZipArchive.unpackedComponents).map { $0.reduce(folder) { $0.appending(path: $1) } }
        }
        projectFile = file(for: project)
        fcpxmlFile = file(for: fcpxml)
    }

    /// Unpacks the rest of the package: its media.
    mutating func unpackMedia() throws {
        do {
            files += try archive.extractAll(into: folder) { [unpacked] in !unpacked.contains($0.path) }
        } catch is ZipArchive.Error {
            throw LumaFusionError.damaged
        }
    }

    /// The folders media might be in: the package's top level, then every
    /// folder that has files in it.
    var mediaFolders: [URL] {
        var folders = [folder.standardizedFileURL]
        for file in files {
            let parent = file.deletingLastPathComponent().standardizedFileURL
            if !folders.contains(parent) { folders.append(parent) }
        }
        return folders
    }

    /// Whether a file is a LumaFusion package: by its type or extension, or,
    /// failing those, by being a ZIP archive with a LumaFusion project file
    /// in it. Other formats are ZIP archives too, so being one isn't enough.
    static func isPackage(_ url: URL) -> Bool {
        if fileExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .lumaFusionPackage) { return true }
        guard !url.hasDirectoryPath, let archive = try? ZipArchive(url: url) else { return false }
        return archive.entries.contains {
            !$0.isDirectory && ($0.fileName as NSString).pathExtension.lowercased() == projectFileExtension
        }
    }
}
