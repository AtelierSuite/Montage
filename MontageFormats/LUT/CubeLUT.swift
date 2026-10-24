import Foundation
import MontageEngine
import UniformTypeIdentifiers

extension UTType {
    /// A colour look-up table in the `.cube` format Resolve, Premiere and
    /// most LUT makers write.
    public static let cubeLUT = UTType(filenameExtension: "cube", conformingTo: .plainText) ?? .plainText
}

/// Reads `.cube` files: the three-dimensional tables of the format Adobe
/// first wrote, now the one nearly every grading tool shares.
///
///     TITLE "Warm"
///     LUT_3D_SIZE 2
///     0 0 0
///     1 0 0
///     …
///
/// The table's rows go red fastest and blue slowest, as `CIColorCube` takes
/// them. One-dimensional tables, and tables over a range other than 0 to 1,
/// aren't read.
public enum CubeLUT {
    /// The table in a file's text, called `name` unless it names itself.
    public static func read(_ text: String, name: String) throws -> ColorLUT {
        var title: String?
        var dimension: Int?
        var values: [Float32] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            // A title is quoted, and may have a # of its own.
            let isTitle = rawLine.trimmingCharacters(in: .whitespaces).hasPrefix("TITLE")
            let line = (isTitle ? rawLine[...] : rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
                .trimmingCharacters(in: .whitespaces)
            guard let keyword = line.split(maxSplits: 1, whereSeparator: \.isWhitespace).first else { continue }
            let rest = line.dropFirst(keyword.count).trimmingCharacters(in: .whitespaces)
            switch keyword {
            case "TITLE":
                title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "LUT_3D_SIZE":
                guard let size = Int(rest), size >= 2 else { throw CubeLUTError.unreadable }
                // Core Image takes cubes of up to 128 points a side, and
                // would leave the picture as it is with a larger one.
                guard size <= 128 else { throw CubeLUTError.unsupported }
                dimension = size
                values.reserveCapacity(size * size * size * 4)
            case "LUT_1D_SIZE":
                throw CubeLUTError.unsupported
            case "DOMAIN_MIN", "DOMAIN_MAX":
                let bound = keyword == "DOMAIN_MIN" ? 0 : 1
                let numbers = rest.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                guard numbers.count == 3 else { throw CubeLUTError.unreadable }
                guard numbers.allSatisfy({ $0 == Double(bound) }) else { throw CubeLUTError.unsupported }
            case "LUT_3D_INPUT_RANGE":
                guard rest.split(whereSeparator: \.isWhitespace).compactMap({ Double($0) }) == [0, 1] else {
                    throw CubeLUTError.unsupported
                }
            default:
                let numbers = line.split(whereSeparator: \.isWhitespace).map { Float32($0) }
                if numbers.count == 3, numbers.allSatisfy({ $0 != nil }) {
                    values += numbers.map { $0! } + [1]
                } else if keyword.first?.isLetter == true {
                    // A keyword of some tool's own, such as a comment
                    // it keeps; nothing the table needs.
                    continue
                } else {
                    throw CubeLUTError.unreadable
                }
            }
        }
        guard let dimension else { throw CubeLUTError.unreadable }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let lut = ColorLUT(name: title ?? name, dimension: dimension, data: data) else {
            throw CubeLUTError.unreadable
        }
        return lut
    }

    /// The table in a file, called after the file unless it names itself.
    public static func read(contentsOf url: URL) throws -> ColorLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try read(text, name: url.deletingPathExtension().lastPathComponent)
    }
}

public enum CubeLUTError: LocalizedError {
    /// Not a `.cube` file, or one cut short.
    case unreadable
    /// A `.cube` file of a kind that isn't supported, such as a 1D table.
    case unsupported

    public var errorDescription: String? {
        switch self {
        case .unreadable: String(localized: "CubeLUT.Error.Unreadable", bundle: #bundle)
        case .unsupported: String(localized: "CubeLUT.Error.Unsupported", bundle: #bundle)
        }
    }
}
