import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Test files from OpenTimelineIO and its adapters, kept in
/// Fixtures/OpenTimelineIO under their own licence (see the NOTICE there).
struct OpenTimelineIOFixtureTests {
    private static func frames(_ count: Int64, _ rate: Int32 = 24) -> CMTime {
        CMTime(value: count, timescale: rate)
    }

    @Test func readsHierosDecimalFrameCounts() throws {
        let imported = try InterchangeFixtures.read("OpenTimelineIO/HieroExport.xml")
        let (_, clip) = try #require(imported.clip("A160C005_171213_R0MN.mxf", on: .video))
        #expect(clip.timelineStart == Self.frames(14))
        #expect(clip.sourceRange == CMTimeRange(start: .zero, duration: Self.frames(1055)))
    }

}
