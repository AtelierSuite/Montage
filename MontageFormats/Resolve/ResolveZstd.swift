import Foundation

/// A zstd decoder, as RFC 8878 describes the format, for the compressed
/// values Resolve writes: clip effect lists and other blobs once they're
/// past a few dozen bytes. Apple's Compression framework has no zstd, and
/// the project takes no dependencies.
///
/// Only what a single frame without a dictionary needs is here: raw, RLE
/// and compressed blocks, Huffman-coded literals and FSE-coded sequences.
/// The optional content checksum isn't checked.
enum ResolveZstd {
    typealias Failure = ResolveBlobs.Failure

    static func decompress(_ frame: Data, maximumSize: Int) throws -> Data {
        var decoder = FrameDecoder(input: [UInt8](frame), maximumSize: maximumSize)
        return Data(try decoder.run())
    }

    // MARK: - Frame

    private struct FrameDecoder {
        let input: [UInt8]
        let maximumSize: Int
        var position = 0
        var output: [UInt8] = []

        // Kept from one block to the next.
        var huffman: HuffmanTable?
        var literalLengths: FSETable?
        var offsets: FSETable?
        var matchLengths: FSETable?
        var repeatOffsets = [1, 4, 8]

        init(input: [UInt8], maximumSize: Int) {
            self.input = input
            self.maximumSize = maximumSize
        }

        mutating func byte() throws -> Int {
            guard position < input.count else { throw Failure.malformed }
            defer { position += 1 }
            return Int(input[position])
        }

        mutating func littleEndian(_ count: Int) throws -> Int {
            var value = 0
            for index in 0..<count { value |= try byte() << (8 * index) }
            return value
        }

        mutating func run() throws -> [UInt8] {
            guard try littleEndian(4) == 0xFD2F_B528 else { throw Failure.malformed }
            let descriptor = try byte()
            let singleSegment = descriptor & 0x20 != 0
            guard descriptor & 0x08 == 0 else { throw Failure.malformed }
            let dictionaryLength = [0, 1, 2, 4][descriptor & 0x03]
            let contentSizeLength = [singleSegment ? 1 : 0, 2, 4, 8][descriptor >> 6]
            if !singleSegment { _ = try byte() }
            guard try littleEndian(dictionaryLength) == 0 else { throw Failure.compressed }
            position += contentSizeLength
            guard position <= input.count else { throw Failure.malformed }

            while true {
                let header = try littleEndian(3)
                let isLast = header & 1 != 0
                let size = header >> 3
                guard size <= 128 * 1024 else { throw Failure.malformed }
                switch (header >> 1) & 3 {
                case 0:
                    guard position + size <= input.count else { throw Failure.malformed }
                    try append(input[position..<(position + size)])
                    position += size
                case 1:
                    let value = UInt8(try byte())
                    try append(repeatElement(value, count: size))
                case 2:
                    guard position + size <= input.count else { throw Failure.malformed }
                    try compressedBlock(Array(input[position..<(position + size)]))
                    position += size
                default:
                    throw Failure.malformed
                }
                if isLast { break }
            }
            return output
        }

        mutating func append<Bytes: Collection>(_ bytes: Bytes) throws where Bytes.Element == UInt8 {
            guard output.count + bytes.count <= maximumSize else { throw Failure.malformed }
            output.append(contentsOf: bytes)
        }

        // MARK: Blocks

        mutating func compressedBlock(_ block: [UInt8]) throws {
            var offset = 0
            let literals = try readLiterals(block, offset: &offset)
            try executeSequences(block, offset: offset, literals: literals)
        }

        mutating func readLiterals(_ block: [UInt8], offset: inout Int) throws -> [UInt8] {
            func at(_ index: Int) throws -> Int {
                guard index < block.count else { throw Failure.malformed }
                return Int(block[index])
            }
            let first = try at(0)
            let type = first & 3
            let sizeFormat = (first >> 2) & 3
            switch type {
            case 0, 1:
                let regenerated: Int
                switch sizeFormat {
                case 0, 2:
                    regenerated = first >> 3
                    offset = 1
                case 1:
                    regenerated = (first >> 4) + (try at(1) << 4)
                    offset = 2
                default:
                    regenerated = (first >> 4) + (try at(1) << 4) + (try at(2) << 12)
                    offset = 3
                }
                if type == 0 {
                    guard offset + regenerated <= block.count else { throw Failure.malformed }
                    defer { offset += regenerated }
                    return Array(block[offset..<(offset + regenerated)])
                }
                let value = UInt8(try at(offset))
                offset += 1
                return [UInt8](repeating: value, count: regenerated)
            default:
                let streams = sizeFormat == 0 ? 1 : 4
                let headerLength = [3, 3, 4, 5][sizeFormat]
                var value = 0
                for index in 0..<headerLength { value |= try at(index) << (8 * index) }
                let fieldBits = [10, 10, 14, 18][sizeFormat]
                let mask = (1 << fieldBits) - 1
                let regenerated = (value >> 4) & mask
                let compressed = (value >> (4 + fieldBits)) & mask
                offset = headerLength
                guard offset + compressed <= block.count else { throw Failure.malformed }
                var data = Array(block[offset..<(offset + compressed)])
                offset += compressed
                if type == 2 {
                    var used = 0
                    huffman = try HuffmanTable(description: data, used: &used)
                    data.removeFirst(used)
                }
                guard let table = huffman else { throw Failure.malformed }
                return try table.decode(data, streams: streams, count: regenerated)
            }
        }

        mutating func executeSequences(_ block: [UInt8], offset start: Int, literals: [UInt8]) throws {
            var offset = start
            func next() throws -> Int {
                guard offset < block.count else { throw Failure.malformed }
                defer { offset += 1 }
                return Int(block[offset])
            }
            let first = try next()
            let count: Int
            if first < 128 {
                count = first
            } else if first < 255 {
                count = ((first - 128) << 8) + (try next())
            } else {
                count = (try next()) + ((try next()) << 8) + 0x7F00
            }
            guard count > 0 else {
                try append(literals)
                return
            }
            let modes = try next()
            literalLengths = try table(
                mode: modes >> 6, block: block, offset: &offset, maximumLog: 9,
                predefined: Self.literalLengthDefault, previous: literalLengths
            )
            offsets = try table(
                mode: (modes >> 4) & 3, block: block, offset: &offset, maximumLog: 8,
                predefined: Self.offsetDefault, previous: offsets
            )
            matchLengths = try table(
                mode: (modes >> 2) & 3, block: block, offset: &offset, maximumLog: 9,
                predefined: Self.matchLengthDefault, previous: matchLengths
            )
            guard let literalTable = literalLengths, let offsetTable = offsets, let matchTable = matchLengths
            else { throw Failure.malformed }

            var bits = try BackwardBits(Array(block[offset...]))
            var literalState = bits.read(literalTable.log)
            var offsetState = bits.read(offsetTable.log)
            var matchState = bits.read(matchTable.log)
            var literalPosition = 0
            for index in 0..<count {
                let offsetCode = Int(offsetTable.symbols[offsetState])
                let matchCode = Int(matchTable.symbols[matchState])
                let literalCode = Int(literalTable.symbols[literalState])
                guard offsetCode <= 31, matchCode < Self.matchLengthCodes.count,
                      literalCode < Self.literalLengthCodes.count else { throw Failure.malformed }
                let offsetValue = (1 << offsetCode) + bits.read(offsetCode)
                let matchCodeInfo = Self.matchLengthCodes[matchCode]
                let matchLength = matchCodeInfo.base + bits.read(matchCodeInfo.bits)
                let literalCodeInfo = Self.literalLengthCodes[literalCode]
                let literalLength = literalCodeInfo.base + bits.read(literalCodeInfo.bits)
                if index < count - 1 {
                    literalState = literalTable.next(literalState, &bits)
                    matchState = matchTable.next(matchState, &bits)
                    offsetState = offsetTable.next(offsetState, &bits)
                }

                let distance: Int
                if offsetValue > 3 {
                    distance = offsetValue - 3
                    repeatOffsets = [distance, repeatOffsets[0], repeatOffsets[1]]
                } else {
                    let repeatIndex = offsetValue - 1 + (literalLength == 0 ? 1 : 0)
                    if repeatIndex == 0 {
                        distance = repeatOffsets[0]
                    } else {
                        distance = repeatIndex < 3 ? repeatOffsets[repeatIndex] : repeatOffsets[0] - 1
                        if repeatIndex > 1 { repeatOffsets[2] = repeatOffsets[1] }
                        repeatOffsets[1] = repeatOffsets[0]
                        repeatOffsets[0] = distance
                    }
                }

                guard literalPosition + literalLength <= literals.count else { throw Failure.malformed }
                try append(literals[literalPosition..<(literalPosition + literalLength)])
                literalPosition += literalLength
                guard distance > 0, distance <= output.count, output.count + matchLength <= maximumSize
                else { throw Failure.malformed }
                let from = output.count - distance
                for step in 0..<matchLength { output.append(output[from + step]) }
            }
            try append(literals[literalPosition...])
        }

        func table(
            mode: Int, block: [UInt8], offset: inout Int, maximumLog: Int, predefined: (counts: [Int], log: Int),
            previous: FSETable?
        ) throws -> FSETable {
            switch mode {
            case 0:
                return try FSETable(counts: predefined.counts, log: predefined.log)
            case 1:
                guard offset < block.count else { throw Failure.malformed }
                defer { offset += 1 }
                return FSETable(single: block[offset])
            case 2:
                return try FSETable(header: block, offset: &offset, maximumLog: maximumLog)
            default:
                guard let previous else { throw Failure.malformed }
                return previous
            }
        }

        // MARK: Codes

        static let literalLengthDefault = (counts: [
            4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
            -1, -1, -1, -1,
        ], log: 6)
        static let matchLengthDefault = (counts: [
            1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
            1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1, -1, -1,
        ], log: 6)
        static let offsetDefault = (counts: [
            1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
        ], log: 5)

        static let literalLengthCodes: [(base: Int, bits: Int)] = (0..<16).map { ($0, 0) } + [
            (16, 1), (18, 1), (20, 1), (22, 1), (24, 2), (28, 2), (32, 3), (40, 3), (48, 4), (64, 6), (128, 7),
            (256, 8), (512, 9), (1024, 10), (2048, 11), (4096, 12), (8192, 13), (16384, 14), (32768, 15), (65536, 16),
        ]
        static let matchLengthCodes: [(base: Int, bits: Int)] = (0..<32).map { ($0 + 3, 0) } + [
            (35, 1), (37, 1), (39, 1), (41, 1), (43, 2), (47, 2), (51, 3), (59, 3), (67, 4), (83, 4), (99, 5),
            (131, 7), (259, 8), (515, 9), (1027, 10), (2051, 11), (4099, 12), (8195, 13), (16387, 14), (32771, 15),
            (65539, 16),
        ]
    }

    // MARK: - Bit streams

    /// A stream read from its end towards its start, as FSE and Huffman
    /// streams are; the last byte's highest set bit marks where it begins.
    /// Reading past the start gives zeros, which the formats allow for.
    struct BackwardBits {
        private let bytes: [UInt8]
        /// The bits not yet read are those below this one.
        private(set) var remaining: Int

        init(_ bytes: [UInt8]) throws {
            guard let last = bytes.last, last != 0 else { throw Failure.malformed }
            self.bytes = bytes
            remaining = bytes.count * 8 - last.leadingZeroBitCount - 1
        }

        mutating func read(_ count: Int) -> Int {
            guard count > 0 else { return 0 }
            remaining -= count
            var value = 0
            for bit in 0..<count {
                let index = remaining + bit
                guard index >= 0 else { continue }
                if bytes[index >> 3] >> (index & 7) & 1 != 0 { value |= 1 << bit }
            }
            return value
        }
    }

    /// A little-endian stream read from its start, as table descriptions are.
    private struct ForwardBits {
        let bytes: [UInt8]
        var position: Int

        func peek(_ count: Int) -> Int {
            var value = 0
            for bit in 0..<count {
                let index = position + bit
                guard index >> 3 < bytes.count else { break }
                if bytes[index >> 3] >> (index & 7) & 1 != 0 { value |= 1 << bit }
            }
            return value
        }

        mutating func read(_ count: Int) -> Int {
            defer { position += count }
            return peek(count)
        }
    }

    // MARK: - FSE

    struct FSETable {
        var log: Int
        var symbols: [UInt8]
        var bitCounts: [Int]
        var bases: [Int]

        init(single symbol: UInt8) {
            log = 0
            symbols = [symbol]
            bitCounts = [0]
            bases = [0]
        }

        /// A table described at `offset`, which is moved past the description.
        init(header: [UInt8], offset: inout Int, maximumLog: Int) throws {
            var bits = ForwardBits(bytes: header, position: offset * 8)
            let log = bits.read(4) + 5
            guard log <= maximumLog else { throw Failure.malformed }
            var remaining = 1 << log
            var counts: [Int] = []
            while remaining > 0, counts.count < 256 {
                let width = Self.highestBit(remaining + 1) + 1
                var value = bits.read(width)
                let lowerMask = (1 << (width - 1)) - 1
                let threshold = (1 << width) - 1 - (remaining + 1)
                if value & lowerMask < threshold {
                    bits.position -= 1
                    value &= lowerMask
                } else if value > lowerMask {
                    value -= threshold
                }
                let count = value - 1
                remaining -= abs(count)
                counts.append(count)
                if count == 0 {
                    var zeros = bits.read(2)
                    while true {
                        for _ in 0..<zeros where counts.count < 256 { counts.append(0) }
                        guard zeros == 3 else { break }
                        zeros = bits.read(2)
                    }
                }
            }
            guard remaining == 0, bits.position <= header.count * 8 else { throw Failure.malformed }
            offset = (bits.position + 7) / 8
            try self.init(counts: counts, log: log)
        }

        init(counts: [Int], log: Int) throws {
            let size = 1 << log
            var symbols = [UInt8](repeating: 0, count: size)
            var next = [Int](repeating: 0, count: counts.count)
            var high = size
            for (symbol, count) in counts.enumerated() where count == -1 {
                high -= 1
                guard high >= 0 else { throw Failure.malformed }
                symbols[high] = UInt8(symbol)
                next[symbol] = 1
            }
            let step = (size >> 1) + (size >> 3) + 3
            var position = 0
            for (symbol, count) in counts.enumerated() where count > 0 {
                next[symbol] = count
                for _ in 0..<count {
                    symbols[position] = UInt8(symbol)
                    repeat { position = (position + step) & (size - 1) } while position >= high
                }
            }
            guard position == 0 else { throw Failure.malformed }
            var bitCounts = [Int](repeating: 0, count: size)
            var bases = [Int](repeating: 0, count: size)
            for state in 0..<size {
                let symbol = Int(symbols[state])
                let nextState = next[symbol]
                next[symbol] += 1
                guard nextState > 0 else { throw Failure.malformed }
                bitCounts[state] = log - Self.highestBit(nextState)
                bases[state] = (nextState << bitCounts[state]) - size
            }
            self.log = log
            self.symbols = symbols
            self.bitCounts = bitCounts
            self.bases = bases
        }

        func next(_ state: Int, _ bits: inout BackwardBits) -> Int {
            bases[state] + bits.read(bitCounts[state])
        }

        static func highestBit(_ value: Int) -> Int {
            Int.bitWidth - 1 - value.leadingZeroBitCount
        }
    }

    // MARK: - Huffman

    struct HuffmanTable {
        var maximumBits: Int
        var symbols: [UInt8]
        var bitCounts: [Int]

        /// A table from a tree description, `used` being how many bytes it took.
        init(description data: [UInt8], used: inout Int) throws {
            guard let header = data.first.map(Int.init) else { throw Failure.malformed }
            var weights: [Int] = []
            if header >= 128 {
                let count = header - 127
                used = 1 + (count + 1) / 2
                guard used <= data.count else { throw Failure.malformed }
                for index in 0..<count {
                    let byte = Int(data[1 + index / 2])
                    weights.append(index % 2 == 0 ? byte >> 4 : byte & 0x0F)
                }
            } else {
                used = 1 + header
                guard used <= data.count else { throw Failure.malformed }
                let description = Array(data[1..<used])
                var offset = 0
                let table = try FSETable(header: description, offset: &offset, maximumLog: 6)
                var bits = try BackwardBits(Array(description[offset...]))
                var first = bits.read(table.log)
                var second = bits.read(table.log)
                while weights.count < 255 {
                    weights.append(Int(table.symbols[first]))
                    first = table.next(first, &bits)
                    if bits.remaining < 0 {
                        weights.append(Int(table.symbols[second]))
                        break
                    }
                    weights.append(Int(table.symbols[second]))
                    second = table.next(second, &bits)
                    if bits.remaining < 0 {
                        weights.append(Int(table.symbols[first]))
                        break
                    }
                }
            }
            // The last symbol's weight is what makes the total a power of two.
            var total = 0
            for weight in weights {
                guard weight <= 11 else { throw Failure.malformed }
                if weight > 0 { total += 1 << (weight - 1) }
            }
            guard total > 0 else { throw Failure.malformed }
            let maximumBits = FSETable.highestBit(total) + 1
            let left = (1 << maximumBits) - total
            guard maximumBits <= 11, left > 0, left & (left - 1) == 0 else { throw Failure.malformed }
            weights.append(FSETable.highestBit(left) + 1)

            let size = 1 << maximumBits
            var symbols = [UInt8](repeating: 0, count: size)
            var bitCounts = [Int](repeating: 0, count: size)
            let lengths = weights.map { $0 > 0 ? maximumBits + 1 - $0 : 0 }
            var rankCount = [Int](repeating: 0, count: maximumBits + 1)
            for length in lengths where length > 0 { rankCount[length] += 1 }
            var rankIndex = [Int](repeating: 0, count: maximumBits + 1)
            for bits in stride(from: maximumBits, through: 1, by: -1) {
                rankIndex[bits - 1] = rankIndex[bits] + rankCount[bits] * (1 << (maximumBits - bits))
            }
            for (symbol, length) in lengths.enumerated() where length > 0 {
                let code = rankIndex[length]
                let span = 1 << (maximumBits - length)
                guard code + span <= size else { throw Failure.malformed }
                for index in code..<(code + span) {
                    symbols[index] = UInt8(symbol)
                    bitCounts[index] = length
                }
                rankIndex[length] += span
            }
            self.maximumBits = maximumBits
            self.symbols = symbols
            self.bitCounts = bitCounts
        }

        func decode(_ data: [UInt8], streams: Int, count: Int) throws -> [UInt8] {
            guard streams == 4 else { return try decodeStream(data[...], count: count) }
            guard data.count >= 6 else { throw Failure.malformed }
            let sizes = (0..<3).map { Int(data[$0 * 2]) | Int(data[$0 * 2 + 1]) << 8 }
            let last = data.count - 6 - sizes.reduce(0, +)
            guard last > 0 else { throw Failure.malformed }
            let segment = (count + 3) / 4
            guard segment * 3 <= count else { throw Failure.malformed }
            var output: [UInt8] = []
            var start = 6
            for (index, size) in (sizes + [last]).enumerated() {
                let length = index < 3 ? segment : count - segment * 3
                output += try decodeStream(data[start..<(start + size)], count: length)
                start += size
            }
            return output
        }

        private func decodeStream(_ data: ArraySlice<UInt8>, count: Int) throws -> [UInt8] {
            var bits = try BackwardBits(Array(data))
            let mask = (1 << maximumBits) - 1
            var state = bits.read(maximumBits)
            var output = [UInt8]()
            output.reserveCapacity(count)
            for _ in 0..<count {
                output.append(symbols[state])
                let length = bitCounts[state]
                state = ((state << length) + bits.read(length)) & mask
            }
            guard bits.remaining >= -maximumBits else { throw Failure.malformed }
            return output
        }
    }
}
