import Foundation
@testable import MontageFormats
import Testing

struct ZipArchiveTests {
    /// Long enough, and repetitive enough, for deflate to make it smaller.
    private static let text = String(repeating: "LumaFusion project package. ", count: 2000)

    @Test(arguments: [false, true])
    func readsStoredAndDeflatedEntries(zip64: Bool) throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let binary = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = try TestZip.write([
            TestZip.File("Project/Stored.txt", Self.text),
            TestZip.File("Project/Deflated.txt", Self.text, deflated: true),
            TestZip.File("Media/Binary.bin", binary, deflated: true),
            TestZip.File("Media/", Data()),
        ], named: "Test.zip", in: folder, zip64: zip64)

        let archive = try ZipArchive(url: url)
        #expect(archive.entries.map(\.path) == ["Project/Stored.txt", "Project/Deflated.txt", "Media/Binary.bin", "Media/"])
        let deflated = try #require(archive.entries.first { $0.path == "Project/Deflated.txt" })
        #expect(deflated.method == ZipArchive.deflated)
        #expect(deflated.compressedSize < deflated.size)
        for entry in archive.entries.prefix(2) {
            #expect(try archive.data(for: entry, limit: 1 << 20) == Data(Self.text.utf8))
        }

        let unpacked = folder.appending(path: "Unpacked", directoryHint: .isDirectory)
        let written = try archive.extractAll(into: unpacked)
        #expect(written.count == 3)
        #expect(try Data(contentsOf: unpacked.appending(path: "Media/Binary.bin")) == binary)
    }

    @Test func readsAnEmptyFileDeflatedWithNoStream() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var empty = TestZip.File("Empty.txt", Data(), deflated: true)
        empty.noStream = true
        var cut = TestZip.File("Cut.txt", Self.text, deflated: true)
        cut.noStream = true
        let archive = try ZipArchive(url: try TestZip.write([empty, cut], named: "Empty.zip", in: folder))
        let entry = try #require(archive.entry(at: "Empty.txt"))
        #expect(entry.method == ZipArchive.deflated)
        #expect(entry.compressedSize == 0)
        #expect(try archive.data(for: entry, limit: 1 << 20) == Data())
        // With nothing to inflate, a file that isn't empty is damaged.
        #expect(throws: ZipArchive.Error.damaged) { try archive.data(for: try #require(archive.entry(at: "Cut.txt")), limit: 1 << 20) }
    }

    @Test func refusesWhatIsntAnArchive() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "Not.zip")
        try Data("<fcpxml version=\"1.11\"/>".utf8).write(to: url)
        #expect(throws: ZipArchive.Error.notAnArchive) { try ZipArchive(url: url) }
        try Data().write(to: url)
        #expect(throws: ZipArchive.Error.notAnArchive) { try ZipArchive(url: url) }
    }

    @Test func refusesDamagedContents() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        var data = try TestZip.archive([TestZip.File("A.txt", Self.text, deflated: true)])
        // Flip a byte in the middle of the compressed contents.
        data[60] ^= 0xFF
        let url = folder.appending(path: "Damaged.zip")
        try data.write(to: url)
        let archive = try ZipArchive(url: url)
        let entry = try #require(archive.entries.first)
        #expect(throws: ZipArchive.Error.self) { try archive.data(for: entry, limit: 1 << 20) }

        // A file cut short loses its central directory.
        let whole = try TestZip.archive([TestZip.File("A.txt", Self.text)])
        try whole.prefix(whole.count / 2).write(to: url)
        #expect(throws: ZipArchive.Error.self) { try ZipArchive(url: url) }
    }

    @Test func refusesEntriesLargerThanAllowed() throws {
        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try TestZip.write([TestZip.File("A.txt", Self.text)], named: "A.zip", in: folder)
        let archive = try ZipArchive(url: url)
        #expect(throws: ZipArchive.Error.damaged) { try archive.data(for: archive.entries[0], limit: 10) }
    }

    @Test func keepsEntriesInsideTheFolder() throws {
        #expect(ZipArchive.safeComponents(of: "Media/Clip.mov") == ["Media", "Clip.mov"])
        #expect(ZipArchive.safeComponents(of: "./Media//Clip.mov") == ["Media", "Clip.mov"])
        #expect(ZipArchive.safeComponents(of: "../Clip.mov") == nil)
        #expect(ZipArchive.safeComponents(of: "Media/../../Clip.mov") == nil)
        #expect(ZipArchive.safeComponents(of: "/etc/passwd") == nil)
        #expect(ZipArchive.safeComponents(of: "..\\Clip.mov") == nil)

        let folder = try TestZip.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try TestZip.write([
            TestZip.File("../Escaped.txt", "out"),
            TestZip.File("__MACOSX/._Clip.mov", "fork"),
            TestZip.File("Inside.txt", "in"),
        ], named: "Paths.zip", in: folder)
        let unpacked = folder.appending(path: "Unpacked", directoryHint: .isDirectory)
        let written = try ZipArchive(url: url).extractAll(into: unpacked)
        #expect(written.map(\.lastPathComponent) == ["Inside.txt"])
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "Escaped.txt").path))
    }

    @Test(arguments: [false, true])
    func readsAnArchiveInMemory(zip64: Bool) throws {
        let binary = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let data = try TestZip.archive([
            TestZip.File("Project/Stored.txt", Self.text),
            TestZip.File("Media/Binary.bin", binary, deflated: true),
        ], zip64: zip64)
        // From a slice that doesn't start at zero, as data read whole may be.
        let archive = try ZipArchive(data: (Data([1, 2, 3]) + data).dropFirst(3))
        #expect(archive.url == nil)
        #expect(archive.entries.map(\.path) == ["Project/Stored.txt", "Media/Binary.bin"])
        let stored = try #require(archive.entry(at: "Project/Stored.txt"))
        #expect(try archive.data(for: stored, limit: 1 << 20) == Data(Self.text.utf8))
        let deflated = try #require(archive.entry(at: "Media/Binary.bin"))
        #expect(try archive.data(for: deflated, limit: 1 << 20) == binary)
        #expect(archive.entry(at: "Missing.txt") == nil)
    }

    @Test func refusesDamagedArchivesInMemory() throws {
        #expect(throws: ZipArchive.Error.notAnArchive) { try ZipArchive(data: Data("<xml/>".utf8)) }
        #expect(throws: ZipArchive.Error.notAnArchive) { try ZipArchive(data: Data()) }
        var data = try TestZip.archive([TestZip.File("A.txt", Self.text, deflated: true)])
        #expect(throws: ZipArchive.Error.self) { try ZipArchive(data: data.prefix(data.count / 2)) }
        data[60] ^= 0xFF
        let archive = try ZipArchive(data: data)
        #expect(throws: ZipArchive.Error.self) { try archive.data(for: archive.entries[0], limit: 1 << 20) }
    }

    @Test func recognizesArchivesByTheirSignature() throws {
        #expect(ZipArchive.hasSignature(try TestZip.archive([TestZip.File("A.txt", "a")])))
        #expect(ZipArchive.hasSignature(try TestZip.archive([])))
        #expect(!ZipArchive.hasSignature(Data("<fcpxml/>".utf8)))
        #expect(!ZipArchive.hasSignature(Data()))
    }

    @Test func checksumsMatchZlibs() {
        #expect(CRC32.checksum(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum(Data()) == 0)
    }
}
