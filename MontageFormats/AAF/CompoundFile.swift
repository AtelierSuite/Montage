import Foundation

/// Reads a Microsoft Compound File Binary file (structured storage), the
/// container AAF files are written in: a little file system of storages
/// (folders) and streams (files) inside one file.
///
///     header                  the first sector: sizes, and where the tables are
///     sectors                 the rest of the file, in sectors of 512 or 4096 bytes
///     ├── FAT                 the next sector of each sector's chain
///     ├── DIFAT               where the FAT's own sectors are, past the header's 109
///     ├── directory           128-byte entries: a red-black tree of each storage's children
///     ├── mini FAT            the chains of the mini stream's 64-byte sectors
///     └── mini stream         the root entry's stream, holding the streams under 4 KB
///
/// Nothing in the file is trusted: chains that loop, sectors past the end of
/// the file and entries that point outside the directory all stop the read
/// with an error, or are left out, rather than crash or run forever.
struct CompoundFile {
    /// The eight bytes every compound file starts with.
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    struct Entry {
        enum Kind: UInt8 {
            /// An unused entry.
            case empty = 0
            case storage = 1
            case stream = 2
            case root = 5
        }

        var name: String
        var kind: Kind
        /// The class of the storage's contents: for AAF, the object's class.
        var classID: [UInt8]
        var left: UInt32
        var right: UInt32
        var child: UInt32
        var startSector: UInt32
        var size: UInt64
    }

    enum ReadError: Error, Equatable {
        /// Not a compound file at all.
        case notCompoundFile
        /// A compound file, but damaged; what was wrong, for debugging.
        case malformed(String)
    }

    private static let freeSector: UInt32 = 0xFFFF_FFFF
    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let lastRegularSector: UInt32 = 0xFFFF_FFFA
    private static let noStream: UInt32 = 0xFFFF_FFFF
    private static let headerDIFATCount = 109
    private static let miniSectorSize = 64

    private let data: Data
    private let sectorSize: Int
    private let miniStreamCutoff: UInt64
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: Data
    /// The directory, in the file's order; entry 0 is the root.
    let entries: [Entry]
    /// Each storage's children by name, as written and with case folded,
    /// so looking one up doesn't walk the tree again.
    private let childNames: [Int: (exact: [String: Int], folded: [String: Int])]

    static func isCompoundFile(_ data: Data) -> Bool {
        data.count >= signature.count && data.prefix(signature.count).elementsEqual(signature)
    }

    init(_ data: Data) throws(ReadError) {
        // Indices from zero, whatever slice the data came as.
        let data = data.startIndex == 0 ? data : Data(data)
        guard Self.isCompoundFile(data), data.count >= 512 else { throw .notCompoundFile }
        self.data = data
        let bytes = ByteView(data)

        guard bytes.u16(28) == 0xFFFE else { throw .malformed("byte order") }
        let sectorShift = bytes.u16(30)
        guard sectorShift == 9 || sectorShift == 12 else { throw .malformed("sector size") }
        sectorSize = 1 << Int(sectorShift)
        guard bytes.u16(32) == 6 else { throw .malformed("mini sector size") }
        let fatSectorCount = Int(bytes.u32(44))
        let firstDirectorySector = bytes.u32(48)
        miniStreamCutoff = UInt64(bytes.u32(56))
        let firstMiniFATSector = bytes.u32(60)
        let firstDIFATSector = bytes.u32(68)
        let difatSectorCount = Int(bytes.u32(72))

        // Sectors after the header's, the last perhaps short.
        let sectorCount = (data.count - 1) / sectorSize
        // A FAT can't need more sectors than the file has.
        guard fatSectorCount <= sectorCount, difatSectorCount <= sectorCount else { throw .malformed("table counts") }

        // Where the FAT's sectors are: 109 in the header, then in DIFAT sectors.
        var fatSectors: [UInt32] = (0..<Self.headerDIFATCount).map { bytes.u32(76 + $0 * 4) }
        var difatSector = firstDIFATSector
        var seenDIFAT: Set<UInt32> = []
        let perDIFAT = sectorSize / 4 - 1
        while difatSector <= Self.lastRegularSector, seenDIFAT.count < difatSectorCount {
            guard seenDIFAT.insert(difatSector).inserted else { throw .malformed("DIFAT loops") }
            guard let offset = Self.offset(ofSector: difatSector, sectorSize: sectorSize, in: data.count) else {
                throw .malformed("DIFAT sector out of range")
            }
            fatSectors += (0..<perDIFAT).map { bytes.u32(offset + $0 * 4) }
            difatSector = bytes.u32(offset + perDIFAT * 4)
        }
        fatSectors = Array(fatSectors.prefix(fatSectorCount))

        var fat: [UInt32] = []
        fat.reserveCapacity(fatSectorCount * sectorSize / 4)
        for sector in fatSectors {
            guard sector <= Self.lastRegularSector,
                  let offset = Self.offset(ofSector: sector, sectorSize: sectorSize, in: data.count) else {
                throw .malformed("FAT sector out of range")
            }
            for index in 0..<sectorSize / 4 { fat.append(bytes.u32(offset + index * 4)) }
        }
        self.fat = fat

        // The directory.
        let directory = try Self.read(chain: firstDirectorySector, fat: fat, sectorSize: sectorSize, data: data)
        let directoryBytes = ByteView(directory)
        var entries: [Entry] = []
        for index in 0..<directory.count / 128 {
            let base = index * 128
            let nameLength = min(Int(directoryBytes.u16(base + 64)), 64)
            let nameUnits = (0..<max(0, nameLength / 2 - 1)).map { directoryBytes.u16(base + $0 * 2) }
            let kind = Entry.Kind(rawValue: directoryBytes.u8(base + 66)) ?? .empty
            var size = directoryBytes.u64(base + 120)
            // Version 3 files have only 32 bits of size; the rest may be junk.
            if sectorSize == 512 { size &= 0xFFFF_FFFF }
            // Unused entries are kept, so indices still line up.
            let isUsed = kind != .empty
            entries.append(Entry(
                name: isUsed ? String(decoding: nameUnits, as: UTF16.self) : "",
                kind: kind,
                classID: Array(directory[base + 80..<base + 96]),
                left: directoryBytes.u32(base + 68), right: directoryBytes.u32(base + 72),
                child: isUsed ? directoryBytes.u32(base + 76) : Self.noStream,
                startSector: directoryBytes.u32(base + 116), size: isUsed ? size : 0
            ))
        }
        guard let root = entries.first, root.kind == .root else { throw .malformed("no root entry") }
        self.entries = entries
        var childNames: [Int: (exact: [String: Int], folded: [String: Int])] = [:]
        for index in entries.indices where entries[index].kind == .storage || entries[index].kind == .root {
            var exact: [String: Int] = [:]
            var folded: [String: Int] = [:]
            // The first of any children with the same name, as the tree's order has it.
            for child in Self.children(of: index, in: entries) {
                let name = entries[child].name
                if exact[name] == nil { exact[name] = child }
                if folded[name.lowercased()] == nil { folded[name.lowercased()] = child }
            }
            childNames[index] = (exact, folded)
        }
        self.childNames = childNames

        // The mini stream and its table, for small streams.
        if root.size > 0, root.startSector <= Self.lastRegularSector {
            let stream = try Self.read(chain: root.startSector, fat: fat, sectorSize: sectorSize, data: data)
            guard UInt64(stream.count) >= root.size else { throw .malformed("mini stream is short") }
            miniStream = stream.prefix(Int(root.size))
        } else {
            miniStream = Data()
        }
        if firstMiniFATSector <= Self.lastRegularSector {
            let table = try Self.read(chain: firstMiniFATSector, fat: fat, sectorSize: sectorSize, data: data)
            let tableBytes = ByteView(table)
            miniFAT = (0..<table.count / 4).map { tableBytes.u32($0 * 4) }
        } else {
            miniFAT = []
        }
    }

    // MARK: - Directory

    /// The entries in a storage, in the tree's order. Siblings that loop or
    /// point outside the directory are left out.
    func children(of index: Int) -> [Int] {
        Self.children(of: index, in: entries)
    }

    private static func children(of index: Int, in entries: [Entry]) -> [Int] {
        guard entries.indices.contains(index) else { return [] }
        var result: [Int] = []
        var visited: Set<Int> = [index]
        var stack: [Int] = []
        var current = Self.index(entries[index].child, in: entries.count)
        // In order: left subtree, the entry, right subtree.
        while current != nil || !stack.isEmpty {
            while let node = current, visited.insert(node).inserted {
                stack.append(node)
                current = Self.index(entries[node].left, in: entries.count)
            }
            guard let node = stack.popLast() else { break }
            result.append(node)
            current = Self.index(entries[node].right, in: entries.count)
        }
        return result
    }

    /// The child of a storage with a name. Names compare as the format
    /// does, ignoring case.
    func child(named name: String, of index: Int) -> Int? {
        guard let names = childNames[index] else { return nil }
        return names.exact[name] ?? names.folded[name.lowercased()]
    }

    // MARK: - Streams

    /// A stream's contents.
    func stream(at index: Int) throws(ReadError) -> Data {
        guard entries.indices.contains(index), entries[index].kind == .stream else {
            throw .malformed("not a stream")
        }
        let entry = entries[index]
        guard entry.size > 0 else { return Data() }
        if entry.size < miniStreamCutoff {
            return try readMini(chain: entry.startSector, size: entry.size)
        }
        let contents = try Self.read(chain: entry.startSector, fat: fat, sectorSize: sectorSize, data: data)
        guard UInt64(contents.count) >= entry.size else { throw .malformed("stream is short") }
        return contents.prefix(Int(entry.size))
    }

    /// A named stream in a storage, or nil if there's none.
    func stream(named name: String, in storage: Int) throws(ReadError) -> Data? {
        guard let index = child(named: name, of: storage), entries[index].kind == .stream else { return nil }
        return try stream(at: index)
    }

    private func readMini(chain start: UInt32, size: UInt64) throws(ReadError) -> Data {
        var result = Data()
        var sector = start
        var visited: Set<UInt32> = []
        while UInt64(result.count) < size {
            guard sector <= Self.lastRegularSector, Int(sector) < miniFAT.count else {
                throw .malformed("mini chain out of range")
            }
            guard visited.insert(sector).inserted else { throw .malformed("mini chain loops") }
            let offset = Int(sector) * Self.miniSectorSize
            guard offset < miniStream.count else { throw .malformed("mini sector out of range") }
            result.append(miniStream[offset..<min(offset + Self.miniSectorSize, miniStream.count)])
            sector = miniFAT[Int(sector)]
        }
        return result.prefix(Int(size))
    }

    /// The sectors of a chain, joined. A chain may end in the file's last,
    /// short sector, as some writers leave it.
    private static func read(chain start: UInt32, fat: [UInt32], sectorSize: Int, data: Data) throws(ReadError) -> Data {
        var result = Data()
        var sector = start
        var visited: Set<UInt32> = []
        while sector != endOfChain {
            guard sector <= lastRegularSector, Int(sector) < fat.count else { throw .malformed("chain out of range") }
            guard visited.insert(sector).inserted else { throw .malformed("chain loops") }
            guard let offset = offset(ofSector: sector, sectorSize: sectorSize, in: data.count, allowShort: true) else {
                throw .malformed("sector out of range")
            }
            result.append(data[offset..<min(offset + sectorSize, data.count)])
            sector = fat[Int(sector)]
        }
        return result
    }

    private static func offset(ofSector sector: UInt32, sectorSize: Int, in count: Int, allowShort: Bool = false) -> Int? {
        let offset = (Int(sector) + 1) * sectorSize
        return (allowShort ? offset < count : offset + sectorSize <= count) ? offset : nil
    }

    private static func index(_ value: UInt32, in count: Int) -> Int? {
        value < UInt32(count) ? Int(value) : nil
    }
}

/// Little-endian numbers read out of bytes, as zero where they'd run past
/// the end, so a short read can't crash.
struct ByteView {
    let data: Data

    init(_ data: Data) {
        self.data = data.startIndex == 0 ? data : Data(data)
    }

    var count: Int { data.count }

    func u8(_ offset: Int) -> UInt8 {
        offset >= 0 && offset < data.count ? data[offset] : 0
    }

    func u16(_ offset: Int) -> UInt16 { UInt16(truncatingIfNeeded: number(offset, size: 2)) }
    func u32(_ offset: Int) -> UInt32 { UInt32(truncatingIfNeeded: number(offset, size: 4)) }
    func u64(_ offset: Int) -> UInt64 { number(offset, size: 8) }
    func i32(_ offset: Int) -> Int32 { Int32(bitPattern: u32(offset)) }
    func i64(_ offset: Int) -> Int64 { Int64(bitPattern: u64(offset)) }

    private func number(_ offset: Int, size: Int) -> UInt64 {
        guard offset >= 0, offset <= data.count - size else { return 0 }
        var value: UInt64 = 0
        for index in (0..<size).reversed() {
            value = value << 8 | UInt64(data[offset + index])
        }
        return value
    }
}
