import Foundation
import MontageEngine
import UniformTypeIdentifiers

extension UTType {
    /// Final Cut Pro's FCPXML, as a single file.
    public static let fcpxml = UTType(importedAs: "com.apple.finalcutpro.xml", conformingTo: .xml)
    /// Final Cut Pro's FCPXML as a bundle, with `Info.fcpxml` inside.
    public static let fcpxmlBundle = UTType(importedAs: "com.apple.finalcutpro.xmld", conformingTo: .package)
}

/// Projects to and from other editors: Final Cut Pro and LumaFusion through
/// FCPXML, and Premiere Pro and Final Cut Pro 7 through Final Cut Pro 7 XML.
public enum ProjectInterchange {
    /// The kinds of file a project can be imported from. Final Cut Pro 7 XML
    /// has no type of its own, so any XML file is offered.
    public static let importableTypes: [UTType] = [.fcpxml, .fcpxmlBundle, .xml]

    // MARK: - Importing

    /// Reads another editor's project from a file, or from an FCPXML bundle.
    /// The project's media isn't looked for yet: see `gatherMedia`.
    public static func read(contentsOf url: URL) throws -> ImportedProject {
        var file = url
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            file = url.appending(path: "Info.fcpxml", directoryHint: .notDirectory)
        }
        return try read(try Data(contentsOf: file), baseURL: file.deletingLastPathComponent())
    }

    /// Reads another editor's project. Media referred to by relative paths
    /// is taken from `baseURL`, the folder the file was in.
    public static func read(_ data: Data, baseURL: URL? = nil) throws -> ImportedProject {
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
    @concurrent
    public static func gatherMedia(
        for imported: ImportedProject, into store: PackageMediaStore, takenPaths: Set<String> = [],
        searchFolders: [URL] = []
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
            for candidate in candidates where FileManager.default.isReadableFile(atPath: candidate.path) {
                guard let path = try? stageCoordinated(candidate, store: store, takenPaths: taken) else { continue }
                guard let staged = store.stagedURL(forPackagePath: path),
                      let probed = try? await MediaProbe.probe(staged) else {
                    store.discardStaged(path)
                    continue
                }
                imported.project.media[index].location = .package(path: path)
                imported.project.media[index].kind = probed.kind
                imported.project.media[index].metadata = probed.metadata
                taken.insert(path)
                found = true
                break
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
        return imported
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
}
