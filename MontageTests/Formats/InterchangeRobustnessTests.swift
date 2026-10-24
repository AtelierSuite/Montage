import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Interchange files made to break the readers: numbers past what a time
/// can hold, references that loop, and nesting too deep to walk.
struct InterchangeRobustnessTests {
    @Test func refusesTimesTooLargeToHold() {
        #expect(InterchangeTime.parse("1e300s") == nil)
        #expect(InterchangeTime.parse("-9223372036854775808/1s") == CMTime(value: .min, timescale: 1))
        #expect(InterchangeTime.parse("9223372036854775807/9223372036854775807s") == CMTime(value: 1, timescale: 1))
        let ntsc = InterchangeTime.frameDuration(timebase: 30, ntsc: true)
        #expect(InterchangeTime.frames(Int64.max / 2, frameDuration: ntsc) == nil)
        #expect(InterchangeTime.frameDuration(timebase: Int64.max / 10, ntsc: true) == CMTime(value: 1, timescale: 30))
    }

    @Test func readsHugeFrameCountsWithoutCrashing() throws {
        let xml = """
            <xmeml version="4"><sequence><name>S</name><rate><timebase>9223372036854775807</timebase><ntsc>TRUE</ntsc></rate>
            <media><video><track><clipitem id="c1"><name>A</name><start>0</start><end>9223372036854775807</end>
            <in>9223372036854775000</in><out>9223372036854775807</out><file id="f1"><name>a.mov</name><pathurl>a.mov</pathurl>
            <media><video/></media></file></clipitem></track></video></media></sequence></xmeml>
            """
        _ = try ProjectInterchange.read(Data(xml.utf8))
    }

    @Test func readsHugeLanesWithoutCrashing() throws {
        let xml = """
            <fcpxml version="1.11"><resources><format id="r1" frameDuration="1/30s" width="1920" height="1080"/>
            <asset id="a1" name="A" start="0s" duration="10s" hasVideo="1" format="r1"><media-rep kind="original-media" src="a.mov"/></asset>
            </resources><library><event><project name="P"><sequence format="r1" tcStart="0s"><spine>
            <asset-clip ref="a1" offset="0s" start="0s" duration="5s">
            <asset-clip ref="a1" lane="9223372036854775807" offset="0s" start="0s" duration="1s"/>
            <spine lane="-9223372036854775807" offset="0s"><asset-clip ref="a1" lane="-9223372036854775807" offset="0s" start="0s" duration="1s"/></spine>
            </asset-clip></spine></sequence></project></event></library></fcpxml>
            """
        _ = try ProjectInterchange.read(Data(xml.utf8))
    }
}
