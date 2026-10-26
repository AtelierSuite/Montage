import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Clip settings in the shape Blackmagic's training projects have them
/// (issue #61), built at test time. No real export is read here.
struct DRPClipSettingsTests {
    private typealias Writer = ResolveBlobWriter

    private func filters(_ filters: [Data], zstd: Bool = true) throws -> [ResolveBlobs.Filter] {
        try ResolveBlobs.filters(Writer.effectFilters(filters, zstd: zstd))
    }

    // MARK: - The blob

    @Test func readsFiltersTheirParametersAndKeyframes() throws {
        let read = try filters([
            Writer.filter(4, [
                Writer.parameter(42, .double(1.5)), nil, nil,
                Writer.parameter(40, .double(0.1), keyframes: [
                    .init(frame: -2, value: 0.25), .init(frame: 40, value: -0.5, curved: true), .init(frame: 70, value: 0),
                ]),
            ]),
            Writer.filter(2, [Writer.parameter(0, .enumeration(6)), nil]),
            Writer.openFX("com.blackmagicdesign.resolvefx.dropshadow"),
        ], zstd: false)
        #expect(read.map(\.type) == [4, 2, 50])
        #expect(read[0].parameters[42] == .init(value: .double(1.5), keyframes: []))
        #expect(read[0].parameters[40]?.keyframes == [
            .init(frame: -2, value: 0.25), .init(frame: 40, value: -0.5), .init(frame: 70, value: 0),
        ])
        #expect(read[0].parameters.count == 2)
        #expect(read[1].parameters[0]?.number == 6)
        #expect(read[1].parameters.count == 1)
        #expect(read[2].plugin == "com.blackmagicdesign.resolvefx.dropshadow")
    }

    @Test func refusesKeyframesWhoseLengthIsWrong() throws {
        var list = Writer.keyframeList([.init(frame: 0, value: 1)])
        #expect(try ResolveBlobs.keyframes(list).count == 1)
        list.append(0)
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.keyframes(list) }
        // A curved keyframe whose handles are missing.
        var curved = Writer.keyframeList([.init(frame: 0, value: 1, curved: true)])
        curved.removeLast(48)
        curved.replaceSubrange(0..<4, with: [0xFF, 0xFF, 0xFF, 0xF0])
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.keyframes(curved) }
    }
}
