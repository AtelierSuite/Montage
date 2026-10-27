import Foundation
import UniformTypeIdentifiers

extension UTType {
    /// An OpenTimelineIO bundle: a ZIP archive of a timeline, `content.otio`,
    /// and the media it uses, in `media/`. Resolve writes these.
    public static let otioz = UTType(importedAs: "io.aswf.opentimelineio.otioz", conformingTo: .zip)
    /// An OpenTimelineIO bundle as a folder: `content.otio` and `media/`.
    public static let otiod = UTType(importedAs: "io.aswf.opentimelineio.otiod", conformingTo: .package)
}

/// An OpenTimelineIO bundle, `.otioz` or `.otiod`: a timeline, `content.otio`,
/// beside the media it uses, in `media/`, which the timeline refers to by
/// paths relative to the bundle.
struct OTIOBundle {
    static let zipExtension = "otioz"
    static let directoryExtension = "otiod"
    static let timelineFileName = "content.otio"

    /// The bundle's folder: the `.otiod` itself, or where an `.otioz` was
    /// unpacked.
    let folder: URL
    let timelineFile: URL
    /// The timeline, read as the bundle's opened, while an `.otiod` in cloud
    /// storage is being read coordinated.
    let timeline: Data

    /// Unpacks an `.otioz` into `folder`, which is made if need be.
    init(unpacking url: URL, into folder: URL) throws {
        let archive: ZipArchive
        let files: [URL]
        do {
            archive = try ZipArchive(url: url)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            files = try archive.extractAll(into: folder)
        } catch is ZipArchive.Error {
            throw InterchangeError.unreadable(nil)
        }
        self.folder = folder
        timelineFile = try Self.timelineFile(among: files, in: folder)
        timeline = try Data(contentsOf: timelineFile)
    }

    /// An `.otiod` folder, read where it is.
    init(folder: URL) throws {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []
        self.folder = folder
        timelineFile = try Self.timelineFile(among: files, in: folder)
        timeline = try Data(contentsOf: timelineFile)
    }

    /// `content.otio` at the top of the bundle, or failing that the
    /// shallowest timeline in it.
    private static func timelineFile(among files: [URL], in folder: URL) throws -> URL {
        let top = folder.appending(path: timelineFileName)
        if FileManager.default.fileExists(atPath: top.path) { return top }
        let timelines = files.filter { $0.pathExtension.lowercased() == "otio" }
        guard let shallowest = timelines.min(by: { $0.pathComponents.count < $1.pathComponents.count }) else {
            throw InterchangeError.noTimeline
        }
        return shallowest
    }

    /// Where the bundle's media might be: its top, its `media` folder, and
    /// beside the timeline.
    var mediaFolders: [URL] {
        var folders = [folder, folder.appending(path: "media", directoryHint: .isDirectory)]
        let beside = timelineFile.deletingLastPathComponent()
        if !folders.contains(where: { $0.standardizedFileURL == beside.standardizedFileURL }) { folders.append(beside) }
        return folders
    }

    /// Whether a file is an OTIO bundle, by its type or extension.
    static func isBundle(_ url: URL) -> Bool {
        if [zipExtension, directoryExtension].contains(url.pathExtension.lowercased()) { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .otioz) || type.conforms(to: .otiod)
    }
}

extension ProjectInterchange {
    /// Whether a file is an OpenTimelineIO bundle, `.otioz` or `.otiod`, to
    /// be imported with `importOTIOBundle` rather than `read`.
    public static func isOTIOBundle(_ url: URL) -> Bool {
        OTIOBundle.isBundle(url)
    }

    /// Imports an OpenTimelineIO bundle: unpacks an `.otioz`, reads its
    /// timeline, and copies the media it carries into staging, as
    /// `gatherMedia` does, looking in the bundle first and then beside it.
    @concurrent
    public static func importOTIOBundle(
        at url: URL, into store: PackageMediaStore, takenPaths: Set<String> = []
    ) async throws -> ImportedProject {
        let unpacked = URL.temporaryDirectory.appending(path: "OTIO-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        let bundle = try coordinatedOpen(url, unpackingInto: unpacked)
        var imported = try read(bundle.timeline, baseURL: bundle.timelineFile.deletingLastPathComponent())
        if imported.name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            imported.name = url.deletingPathExtension().lastPathComponent
        }
        var gathered = await gatherMedia(
            for: imported, into: store, takenPaths: takenPaths,
            searchFolders: bundle.mediaFolders + [url.deletingLastPathComponent()]
        )
        // Media missing from an unpacked bundle is named as in the bundle,
        // not in the folder it was unpacked into, which is about to go.
        let prefix = unpacked.standardizedFileURL.path
        for index in gathered.report.items.indices {
            guard case .missingMedia(let file) = gathered.report.items[index].issue, file.hasPrefix(prefix) else { continue }
            gathered.report.items[index].issue = .missingMedia(file: url.path + file.dropFirst(prefix.count))
        }
        return gathered
    }

    /// Opens the bundle and reads its timeline, coordinated, so one in cloud
    /// storage that isn't on the device yet is downloaded first. An `.otioz`
    /// is unpacked into `folder`; an `.otiod` is read where it is, and its
    /// media copied in later, each file coordinated as it is.
    private static func coordinatedOpen(_ url: URL, unpackingInto folder: URL) throws -> OTIOBundle {
        var coordinationError: NSError?
        var result: Result<OTIOBundle, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: readURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                    return try OTIOBundle(folder: readURL)
                }
                return try OTIOBundle(unpacking: readURL, into: folder)
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }
}
