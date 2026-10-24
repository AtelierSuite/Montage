import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct CubeLUTTests {
    /// A two-point table that swaps red and blue.
    private let swap = """
        # Made by hand
        TITLE "Swap"
        LUT_3D_SIZE 2
        DOMAIN_MIN 0 0 0
        DOMAIN_MAX 1.0 1.0 1.0

        0 0 0
        0 0 1
        0 1 0
        0 1 1
        1 0 0
        1 0 1
        1 1 0
        1 1 1
        """

    @Test func readsATableRedFastest() throws {
        let lut = try CubeLUT.read(swap, name: "File")
        #expect(lut.name == "Swap")
        #expect(lut.dimension == 2)
        let values = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
        #expect(values.count == 32)
        // The second entry is pure red in, and comes out blue.
        #expect(Array(values[4..<8]) == [0, 0, 1, 1])
    }

    @Test func isNamedAfterItsFileWithoutATitle() throws {
        let text = swap.replacingOccurrences(of: "TITLE \"Swap\"\n", with: "")
        #expect(try CubeLUT.read(text, name: "File").name == "File")
    }

    @Test func refusesWhatItCantUse() {
        #expect(throws: CubeLUTError.self) { try CubeLUT.read("LUT_1D_SIZE 2\n0 0 0\n1 1 1", name: "") }
        #expect(throws: CubeLUTError.self) { try CubeLUT.read(swap.replacingOccurrences(of: "DOMAIN_MAX 1.0", with: "DOMAIN_MAX 2.0"), name: "") }
        // Cut short.
        #expect(throws: CubeLUTError.self) { try CubeLUT.read(swap.components(separatedBy: "\n").dropLast().joined(separator: "\n"), name: "") }
        #expect(throws: CubeLUTError.self) { try CubeLUT.read("Not a table", name: "") }
        // Larger than Core Image can apply.
        #expect(throws: CubeLUTError.unsupported) { try CubeLUT.read("LUT_3D_SIZE 129\n0 0 0", name: "") }
    }
}
