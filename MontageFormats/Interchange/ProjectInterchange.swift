import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

extension UTType {
    /// Final Cut Pro's FCPXML, as a single file.
    public static let fcpxml = UTType(importedAs: "com.apple.finalcutpro.xml", conformingTo: .xml)
    /// Final Cut Pro's FCPXML as a bundle, with `Info.fcpxml` inside.
    public static let fcpxmlBundle = UTType(importedAs: "com.apple.finalcutpro.xmld", conformingTo: .package)
    /// The Advanced Authoring Format, by the identifier macOS declares it under.
    public static let aaf = UTType(importedAs: "org.aafassociation.advanced-authoring-format", conformingTo: .compositeContent)
    /// A CMX 3600 edit decision list, which has no system type.
    public static let edl = UTType(importedAs: "com.cmx.edl", conformingTo: .plainText)
    /// An OpenTimelineIO timeline, as JSON.
    public static let otio = UTType(importedAs: "io.aswf.opentimelineio", conformingTo: .json)
    /// A DaVinci Resolve project exported as a `.drp`, a ZIP archive.
    public static let resolveProject = UTType(importedAs: "com.blackmagic-design.resolve.project", conformingTo: .data)
    /// A DaVinci Resolve timeline exported as a `.drt`, laid out as a project is.
    public static let resolveTimeline = UTType(importedAs: "com.blackmagic-design.resolve.timeline", conformingTo: .data)
}

/// Projects to and from other editors: Final Cut Pro and LumaFusion through
/// FCPXML, and Premiere Pro and Final Cut Pro 7 through Final Cut Pro 7 XML.
public enum ProjectInterchange {
    /// The kinds of file a project can be imported from. Final Cut Pro 7 XML
    /// has no type of its own, so any XML file is offered. LumaFusion
    /// packages are imported with `importLumaFusionPackage`, and OTIO bundles
    /// with `importOTIOBundle`.
    public static let importableTypes: [UTType] = [.fcpxml, .fcpxmlBundle] + PremiereProject.types + [
        .xml, .edl, .lumaFusionPackage, .otio, .otioz, .otiod, .aaf, .resolveProject, .resolveTimeline,
    ]

    // MARK: - Importing

    /// Reads another editor's project from a file, or from an FCPXML bundle.
    /// The project's media isn't looked for yet: see `gatherMedia`.
    public static func read(contentsOf url: URL) throws -> ImportedProject {
        var file = url
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            file = url.appending(path: "Info.fcpxml", directoryHint: .notDirectory)
        }
        // Mapped, as an AAF file can carry its media inside.
        var imported = try read(try Data(contentsOf: file, options: .mappedIfSafe), baseURL: file.deletingLastPathComponent())
        // A timeline with no name of its own takes the file's.
        if imported.name?.trimmingCharacters(in: .whitespaces).isEmpty ?? true {
            imported.name = url.deletingPathExtension().lastPathComponent
        }
        return imported
    }

    /// Reads another editor's project. Media referred to by relative paths
    /// is taken from `baseURL`, the folder the file was in.
    public static func read(_ data: Data, baseURL: URL? = nil) throws -> ImportedProject {
        // AAF is binary, in a compound file.
        if CompoundFile.isCompoundFile(data) { return try AAFImporter.read(data, baseURL: baseURL) }
        // Final Cut XML may come gzipped too, and is read uncompressed.
        if GzipInputStream.isGzip(data), let start = GzipInputStream.decompress(data, limit: 4096),
           ["<fcpxml", "<xmeml"].contains(where: String(decoding: start, as: UTF8.self).contains),
           let xml = GzipInputStream.decompress(data) {
            return try read(xml, baseURL: baseURL)
        }
        // Premiere projects are gzipped, and too large to read whole.
        if GzipInputStream.isGzip(data) || PremiereObjectGraph.isPremiereXML(data) {
            return try PremiereProjectImporter.read(data, baseURL: baseURL)
        }
        if EDLImporter.canRead(data) { return try EDLImporter.read(data, baseURL: baseURL) }
        if OTIOImporter.isJSON(data) { return try OTIOImporter.read(data, baseURL: baseURL) }
        // A Resolve project or timeline is a ZIP archive of XML, not XML
        // itself. No other format read here is an archive, so Resolve's
        // reader takes any, and says why it can't read one that isn't its own.
        if ZipArchive.hasSignature(data) { return try DRPImporter.read(data, baseURL: baseURL) }
        let root = try MarkupElement.parse(data)
        switch root.name {
        case "fcpxml": return try FCPXMLImporter.read(root, baseURL: baseURL)
        case "xmeml": return try XMEMLImporter.read(root, baseURL: baseURL)
        default: throw InterchangeError.unsupportedFormat
        }
    }

    /// Looks for the imported project's media and copies what it finds into
    /// staging, to be saved into the project's package, exactly as media
    /// imported into the library is. Each file is looked for where the
    /// project said it was, then by name in `searchFolders` (such as the
    /// folder the project was in). Media that isn't found stays as it is, its
    /// file missing, ready to be relinked, and is listed in the report.
    ///
    /// `staged` holds files already staged for items, at their paths in the
    /// package, as those unpacked from the archive a project came in are:
    /// they're taken ahead of looking anywhere else.
    ///
    /// Clips placed by their picture's shape are placed once it's probed,
    /// and clips timed by their media's timecode are timed from its start.
    @concurrent
    public static func gatherMedia(
        for imported: ImportedProject, into store: PackageMediaStore, takenPaths: Set<String> = [],
        searchFolders: [URL] = [], staged: [MediaItem.ID: String] = [:]
    ) async -> ImportedProject {
        var imported = imported
        var taken = takenPaths
        for index in imported.project.media.indices {
            let item = imported.project.media[index]
            let source = imported.mediaSources[item.id]
            let candidates = ([source].compactMap { $0 } + searchFolders.flatMap { folder in
                [item.name, source?.lastPathComponent].compactMap { $0 }.flatMap { name in
                    [folder.appending(path: name), folder.appending(path: "Media").appending(path: name)]
                }
            }).filter(\.isFileURL)

            var found = false
            if let path = staged[item.id] {
                found = await adopt(path, forItemAt: index, in: &imported, store: store)
                if found { taken.insert(path) }
            }
            for candidate in candidates where !found && FileManager.default.isReadableFile(atPath: candidate.path) {
                guard let path = try? stageCoordinated(candidate, store: store, takenPaths: taken) else { continue }
                found = await adopt(path, forItemAt: index, in: &imported, store: store)
                if found { taken.insert(path) }
            }
            if !found {
                let file = source.map { $0.isFileURL ? $0.path : $0.absoluteString } ?? item.name
                imported.report.add(.missingMedia(file: file), clipName: item.name)
            }
        }
        // Reserved paths of missing media mustn't collide with the found.
        for index in imported.project.media.indices {
            guard case .package(let path) = imported.project.media[index].location,
                  store.stagedURL(forPackagePath: path) == nil else { continue }
            let fresh = ProjectPackage.uniqueMediaPath(for: imported.project.media[index].name, avoiding: taken)
            imported.project.media[index].location = .package(path: fresh)
            taken.insert(fresh)
        }
        imported.placeByProbedPictures()
        imported.startClipsAtTimecode(imported.project.media.reduce(into: [:]) { starts, item in
            guard imported.untimedMedia.contains(item.id), item.kind == .video, case .package(let path) = item.location,
                  store.stagedURL(forPackagePath: path) != nil else { return }
            starts[item.id] = item.metadata.timecode?.time
        })
        if let conform = imported.conformToMedia { imported = conform(imported) }
        return imported
    }

    /// Points an item at a file staged for it, at `path`, with what the file
    /// turns out to be; throws the file away if it can't be read as media.
    private static func adopt(
        _ path: String, forItemAt index: Int, in imported: inout ImportedProject, store: PackageMediaStore
    ) async -> Bool {
        guard let staged = store.stagedURL(forPackagePath: path), let probed = try? await MediaProbe.probe(staged) else {
            store.discardStaged(path)
            return false
        }
        imported.project.media[index].location = .package(path: path)
        imported.project.media[index].kind = probed.kind
        imported.project.media[index].metadata = probed.metadata
        return true
    }

    /// Copies a file into staging, coordinated, so a file in cloud storage
    /// that isn't on the device yet is downloaded first.
    private static func stageCoordinated(_ url: URL, store: PackageMediaStore, takenPaths: Set<String>) throws -> String {
        var coordinationError: NSError?
        var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            result = Result { try store.stage(copying: readURL, takenPaths: takenPaths) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    // MARK: - Exporting

    /// The project as an FCPXML document for Final Cut Pro. `mediaResolver`
    /// finds the media's files, so Final Cut can find them too.
    public static func fcpxml(for project: Project, named name: String, mediaResolver: MediaResolver) -> Data {
        FCPXMLExporter(project: project, name: name, mediaResolver: mediaResolver).document()
    }

    /// The project as an OpenTimelineIO file, for DaVinci Resolve, Premiere
    /// Pro and other apps that read OTIO.
    public static func otio(for project: Project, named name: String, mediaResolver: MediaResolver) -> Data {
        OTIOExporter(project: project, name: name, mediaResolver: mediaResolver).document()
    }

    /// The clips FCPXML can't carry, which are left out: shapes, which have
    /// no generator of Final Cut's to map to, and text with no words, which
    /// Final Cut would fill with its title's own. Other text goes out as
    /// titles.
    public static func clipsLeftOutOfFCPXML(in project: Project) -> [Clip.ID] {
        project.tracks.flatMap(\.clips).filter(FCPXMLExporter.isLeftOut).map(\.id)
    }

    /// The project as a CMX 3600 EDL: its first video track and up to two
    /// audio tracks. `mediaResolver` finds the media's files, so the editor
    /// reading the list can find them too.
    public static func edl(for project: Project, named name: String, mediaResolver: MediaResolver) -> Data {
        EDLExporter(project: project, name: name, mediaResolver: mediaResolver).document()
    }

    /// The clips an EDL can't carry, which are left out: those on video
    /// tracks past the first and audio tracks past what it holds, and text
    /// and shapes.
    public static func clipsLeftOutOfEDL(in project: Project) -> [Clip.ID] {
        EDLExporter.clipsLeftOut(in: project)
    }
}
