import Foundation
@testable import MontageFormats
import Testing

struct CompoundFileTests {
    /// A storage with a small stream, a large one and a storage inside.
    private func writer(sectorSize: Int, largeSize: Int = 10_000) -> CompoundFileTestWriter {
        var writer = CompoundFileTestWriter()
        writer.sectorSize = sectorSize
        writer.root.add(.init(stream: "small", contents: Data("hello".utf8)))
        writer.root.add(.init(stream: "large", contents: Data((0..<largeSize).map { UInt8($0 % 251) })))
        let folder = writer.root.add(.init(storage: "Folder", classID: Array(1...16)))
        folder.add(.init(stream: "inner", contents: Data(repeating: 7, count: 100)))
        for number in 0..<20 { folder.add(.init(stream: "item \(number)", contents: Data([UInt8(number)]))) }
        return writer
    }

    @Test(arguments: [512, 4096])
    func readsStoragesAndStreams(sectorSize: Int) throws {
        let file = try CompoundFile(writer(sectorSize: sectorSize).data())
        #expect(file.entries[0].kind == .root)
        #expect(try file.stream(named: "small", in: 0) == Data("hello".utf8))
        #expect(try file.stream(named: "large", in: 0) == Data((0..<10_000).map { UInt8($0 % 251) }))
        let folder = try #require(file.child(named: "folder", of: 0))
        #expect(file.entries[folder].kind == .storage)
        #expect(file.entries[folder].classID == Array(1...16))
        #expect(try file.stream(named: "inner", in: folder) == Data(repeating: 7, count: 100))
        let names = Set(file.children(of: folder).map { file.entries[$0].name })
        #expect(names == Set(["inner"] + (0..<20).map { "item \($0)" }))
        #expect(try file.stream(named: "item 13", in: folder) == Data([13]))
        #expect(try file.stream(named: "missing", in: 0) == nil)
    }

    /// Past 109 FAT sectors, the rest are listed in DIFAT sectors.
    @Test func readsFilesLargeEnoughToNeedTheDIFAT() throws {
        let size = 8_000_000
        let file = try CompoundFile(writer(sectorSize: 512, largeSize: size).data())
        let large = try #require(try file.stream(named: "large", in: 0))
        #expect(large.count == size)
        #expect(large.last == UInt8((size - 1) % 251))
    }

    @Test func refusesWhatIsntACompoundFile() {
        #expect(throws: CompoundFile.ReadError.notCompoundFile) { try CompoundFile(Data("<xml/>".utf8)) }
        #expect(throws: CompoundFile.ReadError.notCompoundFile) { try CompoundFile(Data(CompoundFile.signature)) }
        #expect(!CompoundFile.isCompoundFile(Data()))
    }

    // MARK: - Damaged files

    private func fatOffset(_ data: Data, sectorSize: Int) -> Int {
        (Int(data.readLE(UInt32.self, at: 76)) + 1) * sectorSize
    }

    @Test(arguments: [512, 4096])
    func stopsAtChainsThatLoop(sectorSize: Int) throws {
        var data = writer(sectorSize: sectorSize).data()
        // The directory's first sector leads back to itself.
        let directory = Int(data.readLE(UInt32.self, at: 48))
        data.setLE(UInt32(directory), at: fatOffset(data, sectorSize: sectorSize) + directory * 4)
        #expect(throws: CompoundFile.ReadError.self) { try CompoundFile(data) }

        // The large stream's chain loops back on itself.
        data = writer(sectorSize: sectorSize).data()
        let file = try CompoundFile(data)
        let large = try #require(file.child(named: "large", of: 0))
        let start = Int(file.entries[large].startSector)
        data.setLE(UInt32(start), at: fatOffset(data, sectorSize: sectorSize) + (start + 1) * 4)
        let damaged = try CompoundFile(data)
        #expect(throws: CompoundFile.ReadError.self) { try damaged.stream(at: large) }
    }

    @Test func stopsAtSectorsPastTheEnd() throws {
        var data = writer(sectorSize: 512).data()
        data.setLE(UInt32(0x00FF_FFFF), at: 48)
        #expect(throws: CompoundFile.ReadError.self) { try CompoundFile(data) }

        data = writer(sectorSize: 512).data()
        data.setLE(UInt32(0x00FF_FFFF), at: 76)
        #expect(throws: CompoundFile.ReadError.self) { try CompoundFile(data) }

        // A FAT count far beyond the file's size.
        data = writer(sectorSize: 512).data()
        data.setLE(UInt32.max, at: 44)
        #expect(throws: CompoundFile.ReadError.self) { try CompoundFile(data) }
    }

    @Test func refusesUnknownSectorSizes() {
        var data = writer(sectorSize: 512).data()
        data.setLE(UInt16(15), at: 30)
        #expect(throws: CompoundFile.ReadError.malformed("sector size")) { try CompoundFile(data) }
    }

    @Test func skipsSiblingsThatLoop() throws {
        var data = writer(sectorSize: 512).data()
        let file = try CompoundFile(data)
        let folder = try #require(file.child(named: "Folder", of: 0))
        let first = Int(file.entries[folder].child)
        // The tree's top entry becomes its own left and right sibling.
        let directory = (Int(data.readLE(UInt32.self, at: 48)) + 1) * 512
        data.setLE(UInt32(first), at: directory + first * 128 + 68)
        data.setLE(UInt32(first), at: directory + first * 128 + 72)
        let damaged = try CompoundFile(data)
        #expect(damaged.children(of: folder) == [first])

        // Siblings past the end of the directory are left out.
        data.setLE(UInt32(9999), at: directory + first * 128 + 68)
        data.setLE(UInt32(0xFFFF_FFF0), at: directory + first * 128 + 72)
        #expect(try CompoundFile(data).children(of: folder) == [first])
    }

    @Test func survivesTruncatedAndScrambledFiles() throws {
        let data = writer(sectorSize: 512).data()
        // Cut short anywhere, it either reads or throws.
        for length in stride(from: 0, to: data.count, by: 97) {
            if let file = try? CompoundFile(data.prefix(length)) {
                for index in file.entries.indices { _ = try? file.stream(at: index) }
            }
        }
        // Bytes overwritten with noise, from a fixed seed.
        var generator = SeededGenerator(seed: 29)
        for _ in 0..<200 {
            var damaged = data
            for _ in 0..<16 {
                damaged[Int.random(in: 0..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            if let file = try? CompoundFile(damaged) {
                for index in file.entries.indices {
                    _ = file.children(of: index)
                    _ = try? file.stream(at: index)
                }
            }
        }
    }
}

/// Random numbers that come out the same each run.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
