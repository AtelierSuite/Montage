import Foundation

/// Writes compound files for the reader's tests: storages and streams in a
/// tree, laid out in sectors of 512 or 4096 bytes, with streams under 4 KB
/// in the mini stream. Not a general writer: everything is written in one
/// go, in an order that's easy to find in a test that damages the file.
struct CompoundFileTestWriter {
    final class Node {
        var name: String
        var isStorage: Bool
        var classID: [UInt8]
        var contents: Data
        var children: [Node] = []

        init(storage name: String, classID: [UInt8] = Array(repeating: 0, count: 16)) {
            self.name = name
            isStorage = true
            self.classID = classID
            contents = Data()
        }

        init(stream name: String, contents: Data) {
            self.name = name
            isStorage = false
            classID = Array(repeating: 0, count: 16)
            self.contents = contents
        }

        @discardableResult
        func add(_ node: Node) -> Node {
            children.append(node)
            return node
        }
    }

    static let freeSector: UInt32 = 0xFFFF_FFFF
    static let endOfChain: UInt32 = 0xFFFF_FFFE
    static let fatSector: UInt32 = 0xFFFF_FFFD
    static let difatSector: UInt32 = 0xFFFF_FFFC
    static let noStream: UInt32 = 0xFFFF_FFFF

    var sectorSize = 512
    var root = Node(storage: "Root Entry")

    func data() -> Data {
        var sectors: [Data] = []
        var fat: [UInt32] = []
        let entriesPerSector = sectorSize / 4

        func allocate(_ bytes: Data, unit: Int, into sectors: inout [Data], table: inout [UInt32]) -> UInt32 {
            guard !bytes.isEmpty else { return Self.endOfChain }
            let start = UInt32(sectors.count)
            var offset = 0
            while offset < bytes.count {
                var sector = bytes.subdata(in: offset..<min(offset + unit, bytes.count))
                sector.append(Data(count: unit - sector.count))
                sectors.append(sector)
                table.append(UInt32(sectors.count))
                offset += unit
            }
            table[table.count - 1] = Self.endOfChain
            return start
        }

        // Flatten the tree into directory entries, the root first.
        var nodes: [Node] = []
        func collect(_ node: Node) {
            nodes.append(node)
            node.children.forEach(collect)
        }
        collect(root)
        func index(of node: Node) -> Int { nodes.firstIndex { $0 === node }! }

        // Small streams into the mini stream, the rest into sectors.
        var miniSectors: [Data] = []
        var miniFAT: [UInt32] = []
        var starts: [Int: UInt32] = [:]
        for (number, node) in nodes.enumerated() where !node.isStorage {
            if node.contents.count < 4096 {
                starts[number] = allocate(node.contents, unit: 64, into: &miniSectors, table: &miniFAT)
            } else {
                starts[number] = allocate(node.contents, unit: sectorSize, into: &sectors, table: &fat)
            }
        }
        let miniStream = miniSectors.reduce(Data(), +)
        let miniStreamStart = allocate(miniStream, unit: sectorSize, into: &sectors, table: &fat)
        var miniFATBytes = Data()
        for value in miniFAT { miniFATBytes.appendLE(value) }
        let miniFATStart = allocate(miniFATBytes, unit: sectorSize, into: &sectors, table: &fat)
        let miniFATCount = (miniFATBytes.count + sectorSize - 1) / sectorSize

        // Each storage's children as a balanced tree, in the format's order.
        var left = [UInt32](repeating: Self.noStream, count: nodes.count)
        var right = left
        var child = left
        func tree(_ children: ArraySlice<Node>) -> UInt32 {
            guard !children.isEmpty else { return Self.noStream }
            let middle = children.startIndex + children.count / 2
            let node = index(of: children[middle])
            left[node] = tree(children[children.startIndex..<middle])
            right[node] = tree(children[(middle + 1)...])
            return UInt32(node)
        }
        for (number, node) in nodes.enumerated() where node.isStorage {
            let sorted = node.children.sorted {
                $0.name.utf16.count != $1.name.utf16.count
                    ? $0.name.utf16.count < $1.name.utf16.count : $0.name.uppercased() < $1.name.uppercased()
            }
            child[number] = tree(sorted[...])
        }

        var directory = Data()
        for (number, node) in nodes.enumerated() {
            var name = Data()
            for unit in node.name.utf16.prefix(31) { name.appendLE(unit) }
            let nameLength = UInt16(name.count + 2)
            name.append(Data(count: 64 - name.count))
            directory.append(name)
            directory.appendLE(nameLength)
            directory.append(number == 0 ? 5 : node.isStorage ? 1 : 2)
            directory.append(1) // black
            directory.appendLE(left[number])
            directory.appendLE(right[number])
            directory.appendLE(child[number])
            directory.append(contentsOf: node.classID)
            directory.append(Data(count: 4 + 16))
            if number == 0 {
                directory.appendLE(miniStream.isEmpty ? Self.endOfChain : miniStreamStart)
                directory.appendLE(UInt64(miniStream.count))
            } else if node.isStorage {
                directory.appendLE(UInt32(0))
                directory.appendLE(UInt64(0))
            } else {
                directory.appendLE(starts[number] ?? Self.endOfChain)
                directory.appendLE(UInt64(node.contents.count))
            }
        }
        while directory.count % sectorSize != 0 {
            var empty = Data(count: 64 + 2 + 2)
            empty.appendLE(Self.noStream)
            empty.appendLE(Self.noStream)
            empty.appendLE(Self.noStream)
            empty.append(Data(count: 128 - empty.count))
            directory.append(empty)
        }
        let directoryStart = allocate(directory, unit: sectorSize, into: &sectors, table: &fat)

        // Enough FAT sectors to map every sector, themselves included, and
        // DIFAT sectors for those past the header's 109.
        var fatCount = 1
        var difatCount = 0
        while true {
            difatCount = max(0, (fatCount - 109 + entriesPerSector - 2) / (entriesPerSector - 1))
            if sectors.count + fatCount + difatCount <= fatCount * entriesPerSector { break }
            fatCount += 1
        }
        let firstFAT = UInt32(sectors.count)
        let fatSectors = (0..<fatCount).map { firstFAT + UInt32($0) }
        let firstDIFAT = firstFAT + UInt32(fatCount)
        fat += Array(repeating: Self.fatSector, count: fatCount) + Array(repeating: Self.difatSector, count: difatCount)
        fat += Array(repeating: Self.freeSector, count: fatCount * entriesPerSector - fat.count)
        for number in 0..<fatCount {
            var sector = Data()
            for value in fat[number * entriesPerSector..<(number + 1) * entriesPerSector] { sector.appendLE(value) }
            sectors.append(sector)
        }
        let overflow = Array(fatSectors.dropFirst(109))
        for number in 0..<difatCount {
            var sector = Data()
            let chunk = overflow.dropFirst(number * (entriesPerSector - 1)).prefix(entriesPerSector - 1)
            for value in chunk { sector.appendLE(value) }
            for _ in chunk.count..<entriesPerSector - 1 { sector.appendLE(Self.freeSector) }
            sector.appendLE(number == difatCount - 1 ? Self.endOfChain : firstDIFAT + UInt32(number + 1))
            sectors.append(sector)
        }

        var header = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        header.append(Data(count: 16))
        header.appendLE(UInt16(0x3E))
        header.appendLE(UInt16(sectorSize == 4096 ? 4 : 3))
        header.appendLE(UInt16(0xFFFE))
        header.appendLE(UInt16(sectorSize == 4096 ? 12 : 9))
        header.appendLE(UInt16(6))
        header.append(Data(count: 6))
        header.appendLE(UInt32(sectorSize == 4096 ? directory.count / sectorSize : 0))
        header.appendLE(UInt32(fatCount))
        header.appendLE(directoryStart)
        header.appendLE(UInt32(0))
        header.appendLE(UInt32(4096))
        header.appendLE(miniFATBytes.isEmpty ? Self.endOfChain : miniFATStart)
        header.appendLE(UInt32(miniFATCount))
        header.appendLE(difatCount > 0 ? firstDIFAT : Self.endOfChain)
        header.appendLE(UInt32(difatCount))
        for number in 0..<109 { header.appendLE(number < fatCount ? fatSectors[number] : Self.freeSector) }
        header.append(Data(count: sectorSize - header.count))

        return sectors.reduce(header, +)
    }
}

extension Data {
    mutating func appendLE<Value: FixedWidthInteger>(_ value: Value) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    /// Writes a little-endian number over bytes already there.
    mutating func setLE<Value: FixedWidthInteger>(_ value: Value, at offset: Int) {
        Swift.withUnsafeBytes(of: value.littleEndian) { replaceSubrange(offset..<offset + $0.count, with: $0) }
    }

    func readLE<Value: FixedWidthInteger>(_: Value.Type, at offset: Int) -> Value {
        var value = Value.zero
        for index in (0..<MemoryLayout<Value>.size).reversed() {
            value = value << 8 | Value(self[startIndex + offset + index])
        }
        return value
    }
}
