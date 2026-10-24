import CoreMedia
@testable import MontageEngine
import Testing

struct FrameTimeTests {
    private let ntsc = FrameTime(frameDuration: CMTime(value: 1001, timescale: 30000))

    @Test func findsTheFrameShowingAtATime() {
        let frames = FrameTime(frameDuration: CMTime(value: 1, timescale: 30))
        #expect(frames.frame(at: .zero) == 0)
        #expect(frames.frame(at: CMTime(value: 1, timescale: 30)) == 1)
        #expect(frames.frame(at: CMTime(value: 59, timescale: 60)) == 29)
        #expect(frames.snapped(CMTime(value: 61, timescale: 60)) == CMTime(value: 30, timescale: 30))
        // Exactly on a frame at 29.97, however long in.
        let frame = ntsc.time(ofFrame: 107_892)
        #expect(ntsc.frame(at: frame) == 107_892)
    }

    @Test func writesTimecode() {
        let frames = FrameTime(frameDuration: CMTime(value: 1, timescale: 30))
        #expect(frames.timecode(.zero) == "00:00:00:00")
        #expect(frames.timecode(CMTime(value: 3_723 * 30 + 4, timescale: 30)) == "01:02:03:04")
        // 29.97 counts 30 frames a second, without dropping any.
        #expect(ntsc.timecodeRate == 30)
        #expect(ntsc.timecode(ntsc.time(ofFrame: 30)) == "00:00:01:00")
    }
}
