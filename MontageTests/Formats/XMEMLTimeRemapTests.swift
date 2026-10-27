import Foundation
@testable import MontageFormats
import Testing

/// Premiere's Time Remap, as it writes it into Final Cut Pro 7 XML.
struct XMEMLTimeRemapTests {
    private func project(remap parameters: String) -> String {
        """
        <xmeml version="4"><sequence><name>S</name><rate><timebase>30</timebase></rate>
        <media><video><track><clipitem id="c1"><name>A</name><start>0</start><end>30</end><in>0</in><out>30</out>
        <file id="f1"><name>a.mov</name><pathurl>a.mov</pathurl><media><video/></media></file>
        <filter><effect><name>Time Remap</name><effectid>timeremap</effectid><mediatype>video</mediatype>
        \(parameters)
        </effect></filter></clipitem></track></video></media></sequence></xmeml>
        """
    }

    private func parameter(_ id: String, _ value: String) -> String {
        "<parameter><parameterid>\(id)</parameterid><name>\(id)</name><value>\(value)</value></parameter>"
    }

    private func issues(_ parameters: String) throws -> [ImportReport.Issue] {
        try ProjectInterchange.read(Data(project(remap: parameters).utf8)).report.items.map(\.issue)
    }

    @Test func reportsAClipPlayedBackwardsAtNormalSpeed() throws {
        let reversed = parameter("variablespeed", "0") + parameter("speed", "100") + parameter("reverse", "TRUE")
        #expect(try issues(reversed).contains(.speedChange))
    }

    @Test func reportsASpeedGraph() throws {
        #expect(try issues(parameter("variablespeed", "1") + parameter("speed", "100")).contains(.speedChange))
    }

    @Test func leavesNormalSpeedAlone() throws {
        let normal = parameter("variablespeed", "0") + parameter("speed", "100") + parameter("reverse", "FALSE")
        #expect(try !issues(normal).contains(.speedChange))
    }

    @Test func refusesAFilterOnItsOwn() {
        // OpenTimelineIO's test data has a lone <filter>, which isn't a
        // project.
        let fragment = "<filter><effect><name>Time Remap</name><effectid>timeremap</effectid></effect></filter>"
        #expect(throws: InterchangeError.unsupportedFormat) { try ProjectInterchange.read(Data(fragment.utf8)) }
    }
}
