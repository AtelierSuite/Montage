import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Media in folders the app can't read until the user allows it, as beside
/// a project picked in a sandbox: asked for once, then found.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct FolderAccessTests {
    private actor Requests {
        var folders: [URL] = []
        func add(_ folder: URL) { folders.append(folder) }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "FolderAccess-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.standardizedFileURL
    }

    private func setLocked(_ folder: URL, _ locked: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: locked ? 0 : 0o755], ofItemAtPath: folder.path)
    }

    /// A project naming one movie per entry, at the path given, or by name only.
    private func project(naming files: [(name: String, source: URL?)]) -> ImportedProject {
        var sources: [MediaItem.ID: URL] = [:]
        let media = files.map { file in
            let item = MediaItem(
                name: file.name, kind: .video, location: .package(path: ProjectPackage.mediaPath(forFileName: file.name)),
                metadata: MediaMetadata()
            )
            sources[item.id] = file.source
            return item
        }
        return ImportedProject(
            project: Project(media: media), report: ImportReport(format: .xmeml), name: nil, mediaSources: sources
        )
    }

    @Test func asksOnceForTheLockedFolderBesideTheProjectThenFindsItsMedia() async throws {
        let folder = try makeFolder()
        try await TestMovie.write(to: folder.appending(path: "A.mov"), width: 64, height: 64)
        try await TestMovie.write(to: folder.appending(path: "B.mov"), width: 64, height: 64)
        try setLocked(folder, true)
        defer { try? setLocked(folder, false) }

        let requests = Requests()
        let imported = project(naming: [("A.mov", folder.appending(path: "A.mov")), ("B.mov", nil)])
        let gathered = await ProjectInterchange.gatherMedia(
            for: imported, into: PackageMediaStore(), searchFolders: [folder]
        ) { asked in
            await requests.add(asked)
            try? setLocked(folder, false)
            return asked
        }
        #expect(await requests.folders == [folder])
        #expect(gathered.report.items(in: .missingMedia).isEmpty)
    }

    @Test func leavesMediaMissingWhenAccessIsDeclined() async throws {
        let folder = try makeFolder()
        try await TestMovie.write(to: folder.appending(path: "A.mov"), width: 64, height: 64)
        try setLocked(folder, true)
        defer { try? setLocked(folder, false) }

        let requests = Requests()
        let gathered = await ProjectInterchange.gatherMedia(
            for: project(naming: [("A.mov", nil)]), into: PackageMediaStore(), searchFolders: [folder]
        ) { asked in
            await requests.add(asked)
            return nil
        }
        #expect(await requests.folders.count == 1)
        #expect(gathered.report.items(in: .missingMedia).count == 1)
    }

    @Test func searchesAnotherFolderTheUserChooses() async throws {
        let locked = try makeFolder()
        let elsewhere = try makeFolder()
        try await TestMovie.write(to: elsewhere.appending(path: "A.mov"), width: 64, height: 64)
        try setLocked(locked, true)
        defer { try? setLocked(locked, false) }

        let gathered = await ProjectInterchange.gatherMedia(
            for: project(naming: [("A.mov", nil)]), into: PackageMediaStore(), searchFolders: [locked]
        ) { _ in elsewhere }
        #expect(gathered.report.items(in: .missingMedia).isEmpty)
    }

    @Test func doesNotAskWhenTheMediaCanBeRead() async throws {
        let folder = try makeFolder()
        try await TestMovie.write(to: folder.appending(path: "A.mov"), width: 64, height: 64)
        let requests = Requests()
        let gathered = await ProjectInterchange.gatherMedia(
            for: project(naming: [("A.mov", nil)]), into: PackageMediaStore(), searchFolders: [folder]
        ) { asked in
            await requests.add(asked)
            return nil
        }
        #expect(await requests.folders.isEmpty)
        #expect(gathered.report.items(in: .missingMedia).isEmpty)
    }

    @Test func doesNotAskForFoldersThatAreNotThere() async throws {
        let folder = try makeFolder()
        let away = URL(filePath: "/Volumes/Not Here \(UUID().uuidString)/Footage/A.mov")
        let imported = project(naming: [("A.mov", away)])
        #expect(ProjectInterchange.folderNeedingAccess(for: imported, searchFolders: [folder]) == nil)
    }

    @Test func asksForTheFolderHoldingEveryLockedFolder() throws {
        let root = try makeFolder()
        let project = root.appending(path: "Project", directoryHint: .isDirectory)
        let footage = root.appending(path: "Footage/Day 1", directoryHint: .isDirectory)
        for folder in [project, footage] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try setLocked(folder, true)
        }
        defer { for folder in [project, footage] { try? setLocked(folder, false) } }

        let imported = self.project(naming: [("A.mov", footage.appending(path: "A.mov"))])
        let asked = ProjectInterchange.folderNeedingAccess(for: imported, searchFolders: [project])
        #expect(asked?.standardizedFileURL.path == root.path)
    }
}
