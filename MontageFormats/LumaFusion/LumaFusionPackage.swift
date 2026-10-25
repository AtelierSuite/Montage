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
/// What's known of the format, from LumaFusion's reference guide and one
/// open-source reader checked against packages from LumaFusion 5.5: the
/// package is a ZIP archive, possibly ZIP64, its media stored uncompressed
/// beside a single `*.lfarchive` file, which holds the project as JSON. How
/// the media is laid out in folders isn't known, so it's looked for by name
/// wherever it is in the archive.
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
    let files: [URL]

    /// Unpacks the package at `url` into `folder`, which is made if need be.
    init(unpacking url: URL, into folder: URL) throws {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(url: url)
        } catch let error as ZipArchive.Error {
            throw error == .notAnArchive ? LumaFusionError.notAPackage : LumaFusionError.damaged
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            files = try archive.extractAll(into: folder)
        } catch is ZipArchive.Error {
            throw LumaFusionError.damaged
        }
        self.folder = folder
        projectFile = Self.shallowest(files.filter { $0.pathExtension.lowercased() == Self.projectFileExtension })
        fcpxmlFile = Self.shallowest(files.filter { $0.pathExtension.lowercased() == "fcpxml" })
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
    /// failing those, by being a ZIP archive.
    static func isPackage(_ url: URL) -> Bool {
        if fileExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
           type.conforms(to: .lumaFusionPackage) { return true }
        guard !url.hasDirectoryPath, let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    private static func shallowest(_ files: [URL]) -> URL? {
        files.min { $0.pathComponents.count < $1.pathComponents.count }
    }
}
