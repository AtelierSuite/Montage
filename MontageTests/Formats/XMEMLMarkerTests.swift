import CoreMedia
import Foundation
@testable import MontageFormats
import Testing

/// Sequence and clip markers in Final Cut Pro 7 XML, as Premiere writes them.
struct XMEMLMarkerTests {
    private func frames(_ count: Int64) -> CMTime {
        CMTime(value: count, timescale: 30)
    }

    private func marker(_ name: String, at frame: Int, comment: String = "", out: Int = -1) -> String {
        "<marker><comment>\(comment)</comment><name>\(name)</name><in>\(frame)</in><out>\(out)</out></marker>"
    }

    /// A clip 60 to 120 frames into a.mov, at frame 30 of the sequence.
    private func clip(_ markers: String, enabled: Bool = true) -> String {
        """
        <clipitem id="c1"><name>A</name><enabled>\(enabled ? "TRUE" : "FALSE")</enabled>
        <start>30</start><end>90</end><in>60</in><out>120</out>
        <file id="f1"><name>a.mov</name><pathurl>a.mov</pathurl><media><video/></media></file>
        \(markers)</clipitem>
        """
    }

    private func read(_ items: String, sequenceMarkers: String = "") throws -> ImportedProject {
        let xml = """
            <xmeml version="4"><sequence><name>S</name><rate><timebase>30</timebase></rate>
            <media><video><track>\(items)</track></video></media>\(sequenceMarkers)</sequence></xmeml>
            """
        return try ProjectInterchange.read(Data(xml.utf8))
    }

    @Test func importsSequenceMarkersInOrder() throws {
        let imported = try read(clip(""), sequenceMarkers: marker("Outro", at: 80) + marker("Intro", at: 10))
        #expect(imported.project.markers.map(\.time) == [frames(10), frames(80)])
        #expect(imported.project.markers.map(\.name) == ["Intro", "Outro"])
        #expect(!imported.report.items.contains { if case .marker = $0.issue { true } else { false } })
    }

    @Test func namesAMarkerByItsCommentIfItHasNoName() throws {
        let imported = try read(clip(""), sequenceMarkers: marker("", at: 5, comment: "Fix the sound"))
        #expect(imported.project.markers.map(\.name) == ["Fix the sound"])
    }

    @Test func marksARangeMarkerWhereItStarts() throws {
        let imported = try read(clip(""), sequenceMarkers: marker("Range", at: 12, out: 40))
        #expect(imported.project.markers.map(\.time) == [frames(12)])
    }

    @Test func placesAClipsMarkersOnTheTimeline() throws {
        // Timed in the media: frame 75 is 15 frames into the clip.
        let imported = try read(clip(marker("Take 2", at: 75)))
        #expect(imported.project.markers.map(\.time) == [frames(45)])
        #expect(imported.project.markers.map(\.name) == ["Take 2"])
    }

    @Test func leavesOutAClipsMarkersOnMediaTrimmedOff() throws {
        let imported = try read(clip(marker("Before", at: 10) + marker("After", at: 120) + marker("Last", at: 119)))
        #expect(imported.project.markers.map(\.name) == ["Last"])
    }

    @Test func keepsTheMarkersOfADisabledClip() throws {
        let imported = try read(clip(marker("Take 2", at: 75), enabled: false))
        #expect(imported.project.markers.map(\.time) == [frames(45)])
    }

    @Test func placesANestedSequencesMarkersWhereTheyreShown() throws {
        // The nested sequence is played from its frame 20, at frame 30;
        // only its markers from 20 to 50 are seen.
        let nested = """
            <clipitem id="n1"><name>Nest</name><start>30</start><end>60</end><in>20</in><out>50</out>
            <sequence id="s2"><name>Inner</name><rate><timebase>30</timebase></rate>
            <media><video><track>
            <clipitem id="c2"><name>B</name><start>0</start><end>100</end><in>0</in><out>100</out>
            <file id="f2"><name>b.mov</name><pathurl>b.mov</pathurl><media><video/></media></file>
            \(marker("Clip inside", at: 25))</clipitem>
            </track></video></media>
            \(marker("Too early", at: 5) + marker("Inside", at: 40) + marker("Too late", at: 50))
            </sequence></clipitem>
            """
        let imported = try read(nested)
        #expect(imported.project.markers.map(\.name) == ["Clip inside", "Inside"])
        #expect(imported.project.markers.map(\.time) == [frames(35), frames(50)])
    }
}
