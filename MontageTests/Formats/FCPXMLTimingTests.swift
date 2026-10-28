import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Markers, transitions and speed changes in FCPXML, read from small files
/// made up for each test.
struct FCPXMLTimingTests {
    private static func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
        CMTime(value: value, timescale: timescale)
    }

    /// A project of two 10-second assets at 30 fps whose spine is `spine`.
    private func read(spine: String) throws -> ImportedProject {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.11">
            <resources>
                <format id="r1" frameDuration="1/30s" width="1920" height="1080"/>
                <asset id="a1" name="One" start="0s" duration="10s" hasVideo="1" hasAudio="1" format="r1">
                    <media-rep kind="original-media" src="file:///Volumes/Media/One.mov"/>
                </asset>
                <asset id="a2" name="Two" start="0s" duration="10s" hasVideo="1" hasAudio="1" format="r1">
                    <media-rep kind="original-media" src="file:///Volumes/Media/Two.mov"/>
                </asset>
                <effect id="e1" name="Cross Dissolve" uid="FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"/>
            </resources>
            <library>
                <event name="Event">
                    <project name="Timing">
                        <sequence format="r1" tcStart="0s">
                            <spine>
                                \(spine)
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>
        """
        return try ProjectInterchange.read(Data(xml.utf8), baseURL: nil)
    }

    // MARK: - Markers

    @Test func putsMarkersOnTheTimeline() throws {
        let imported = try read(spine: """
            <asset-clip ref="a1" offset="0s" name="One" start="2s" duration="4s">
                <marker start="3s" duration="1/30s" value="Look here"/>
                <chapter-marker start="5s" duration="1/30s" value="Chapter 2" posterOffset="0s"/>
                <marker start="7s" duration="1/30s" value="Trimmed off"/>
            </asset-clip>
            <asset-clip ref="a2" offset="4s" name="Two" start="0s" duration="2s">
                <marker start="0s" duration="1/30s" value=""/>
            </asset-clip>
            """)
        // In the clip's own time, which starts at 2s at the start of the timeline.
        #expect(imported.project.markers.map(\.time) == [Self.seconds(1), Self.seconds(3), Self.seconds(4)])
        #expect(imported.project.markers.map(\.name) == ["Look here", "Chapter 2", ""])
        #expect(!imported.report.items.contains { if case .marker = $0.issue { true } else { false } })
    }

    @Test func leavesOutMarkersHiddenByTheClipsTheyreInside() throws {
        let imported = try read(spine: """
            <clip offset="0s" name="Outer" start="1s" duration="2s">
                <asset-clip ref="a1" offset="0s" name="One" start="0s" duration="5s">
                    <marker start="2s" duration="1/30s" value="Shown"/>
                    <marker start="4s" duration="1/30s" value="Hidden"/>
                </asset-clip>
            </clip>
            """)
        #expect(imported.project.markers.map(\.name) == ["Shown"])
        #expect(imported.project.markers.map(\.time) == [Self.seconds(1)])
    }
}
