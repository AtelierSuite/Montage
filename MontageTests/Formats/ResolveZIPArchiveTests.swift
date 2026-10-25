import Foundation
@testable import MontageFormats
import Testing

struct ResolveZIPArchiveTests {
    private func sample(zip64: Bool = false) -> Data {
        var writer = ZIPTestWriter()
        writer.zip64 = zip64
        writer.add("project.xml", String(repeating: "<a>deflated</a>", count: 200))
        writer.add("SeqContainer/One.xml", "stored", deflated: false)
        writer.add("MediaPool/Master/", "", deflated: false)
        writer.add("Empty.xml", "")
        return writer.archive()
    }

    @Test func readsStoredAndDeflatedEntries() throws {
        let archive = try ResolveZIPArchive(sample())
        #expect(archive.entries.map(\.name) == ["project.xml", "SeqContainer/One.xml", "MediaPool/Master/", "Empty.xml"])
        #expect(archive.entries[2].isDirectory)
        #expect(try archive.contents(of: "project.xml") == Data(String(repeating: "<a>deflated</a>", count: 200).utf8))
        #expect(try archive.contents(of: "SeqContainer/One.xml") == Data("stored".utf8))
        #expect(try archive.contents(of: "Empty.xml").isEmpty)
        #expect(throws: ResolveZIPArchive.Failure.missingEntry("Gallery.xml")) { try archive.contents(of: "Gallery.xml") }
    }

    @Test func readsZIP64Records() throws {
        let archive = try ResolveZIPArchive(sample(zip64: true))
        #expect(archive.entries.count == 4)
        #expect(archive.entries[1].localHeaderOffset > 0)
        #expect(try archive.contents(of: "SeqContainer/One.xml") == Data("stored".utf8))
        #expect(try archive.contents(of: "project.xml").count == 15 * 200)
    }

    @Test func readsAnArchiveFromASlice() throws {
        let padded = Data([1, 2, 3]) + sample()
        let archive = try ResolveZIPArchive(padded.dropFirst(3))
        #expect(try archive.contents(of: "SeqContainer/One.xml") == Data("stored".utf8))
    }

    @Test func recognizesArchivesByTheirFirstBytes() {
        #expect(ResolveZIPArchive.looksLikeArchive(sample()))
        #expect(ResolveZIPArchive.looksLikeArchive(ZIPTestWriter().archive()))
        #expect(!ResolveZIPArchive.looksLikeArchive(Data("<xml/>".utf8)))
        #expect(!ResolveZIPArchive.looksLikeArchive(Data()))
    }

    @Test func refusesWhatIsntAnArchive() {
        #expect(throws: ResolveZIPArchive.Failure.notAnArchive) { try ResolveZIPArchive(Data("PK\u{3}\u{4} not really".utf8)) }
        #expect(throws: ResolveZIPArchive.Failure.notAnArchive) { try ResolveZIPArchive(Data()) }
        // Cut off before its directory.
        #expect(throws: ResolveZIPArchive.Failure.notAnArchive) { try ResolveZIPArchive(sample().prefix(40)) }
    }

    @Test func refusesDamagedEntries() throws {
        var damaged = sample()
        // A byte of the stored entry's contents, which no longer match their CRC.
        let range = try #require(damaged.range(of: Data("stored".utf8)))
        damaged[range.lowerBound] = UInt8(ascii: "S")
        let archive = try ResolveZIPArchive(damaged)
        #expect(throws: ResolveZIPArchive.Failure.corrupt) { try archive.contents(of: "SeqContainer/One.xml") }
        // The others are still fine.
        #expect(try archive.contents(of: "project.xml").count == 15 * 200)
    }

    @Test func refusesADirectoryPointingPastTheEnd() {
        var damaged = sample()
        // The end record's directory offset, pushed past the end.
        let end = damaged.count - 22
        damaged.replaceSubrange((end + 16)..<(end + 20), with: [0xFF, 0xFF, 0xFF, 0x7F])
        #expect(throws: ResolveZIPArchive.Failure.corrupt) { try ResolveZIPArchive(damaged) }
    }

    @Test func refusesEncryptedAndUnknownMethods() throws {
        var writer = ZIPTestWriter()
        writer.add("a.xml", "a", deflated: false)
        var data = writer.archive()
        let directory = try #require(data.range(of: Data([0x50, 0x4B, 0x01, 0x02]))).lowerBound
        // Compression method 14, LZMA.
        data[directory + 10] = 14
        #expect(throws: ResolveZIPArchive.Failure.unsupportedMethod(14)) { try ResolveZIPArchive(data).contents(of: "a.xml") }
        data[directory + 10] = 0
        data[directory + 8] |= 1
        #expect(throws: ResolveZIPArchive.Failure.encrypted) { try ResolveZIPArchive(data).contents(of: "a.xml") }
    }

    @Test func checksumsMatchTheStandard() {
        #expect(ResolveZIPArchive.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
    }
}
