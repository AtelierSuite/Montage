import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Basic Motion's centre, which Premiere writes as a fraction of the media's
/// own size, as its exports of its own presets show.
struct XMEMLMotionTests {
    /// A sequence `frame` in size with one clip of media `media` in size,
    /// its Basic Motion parameters `parameters`.
    private func read(frame: CGSize, media: CGSize?, _ parameters: String) throws -> ImportedProject {
        let characteristics = media.map {
            "<samplecharacteristics><width>\(Int($0.width))</width><height>\(Int($0.height))</height></samplecharacteristics>"
        } ?? ""
        let xml = """
            <xmeml version="4"><sequence><name>S</name><rate><timebase>30</timebase></rate>
            <media><video><format><samplecharacteristics><width>\(Int(frame.width))</width><height>\(Int(frame.height))</height>
            </samplecharacteristics></format><track>
            <clipitem id="c1"><name>A</name><start>0</start><end>60</end><in>100</in><out>160</out>
            <file id="f1"><name>a.mov</name><pathurl>a.mov</pathurl><media><video>\(characteristics)</video></media></file>
            <filter><effect><name>Basic Motion</name><effectid>basic</effectid><mediatype>video</mediatype>
            \(parameters)</effect></filter></clipitem>
            </track></video></media></sequence></xmeml>
            """
        return try ProjectInterchange.read(Data(xml.utf8))
    }

    private func center(_ horizontal: Double, _ vertical: Double, keyframes: String = "") -> String {
        """
        <parameter><parameterid>center</parameterid><name>Center</name>
        <value><horiz>\(horizontal)</horiz><vert>\(vertical)</vert></value>\(keyframes)</parameter>
        """
    }

    private func position(_ imported: ImportedProject) throws -> Animatable<CGPoint> {
        try #require(imported.project.tracks.first?.clips.first).transform.position
    }

    @Test func movesAWidePictureByItsOwnWidth() throws {
        // Premiere's preset moves a 3840 by 1080 capture 1260 pixels left
        // and 20 down in an HD frame, and writes it as this.
        let imported = try read(frame: CGSize(width: 1920, height: 1080), media: CGSize(width: 3840, height: 1080),
                                center(-0.328125, 0.0185185))
        let point = try position(imported).value
        #expect(abs(point.x - (960 - 1260) / 1920.0) < 0.000001)
        #expect(abs(point.y - (540 + 20) / 1080.0) < 0.00001)
    }

    @Test func movesAScaledPictureByItsSizeUnscaled() throws {
        // An eye of an over-under stereo frame: 4096 by 2048 at 140.7%,
        // 1440 pixels below the middle of a 5760 pixel square.
        let imported = try read(frame: CGSize(width: 5760, height: 5760), media: CGSize(width: 4096, height: 2048),
                                center(0, 0.703125))
        #expect(try position(imported).value == CGPoint(x: 0.5, y: 0.75))
    }

    @Test func movesKeyframesTheSameWay() throws {
        let keyframes = """
            <keyframe><when>100</when><value><horiz>0</horiz><vert>0</vert></value></keyframe>
            <keyframe><when>130</when><value><horiz>0.25</horiz><vert>0</vert></value></keyframe>
            """
        let imported = try read(frame: CGSize(width: 1920, height: 1080), media: CGSize(width: 3840, height: 1080),
                                center(0, 0, keyframes: keyframes))
        let position = try position(imported)
        // Timed in the media, from the in point at frame 100.
        #expect(position.keyframes.map(\.time) == [.zero, CMTime(value: 30, timescale: 30)])
        #expect(position.keyframes.map(\.value) == [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 1, y: 0.5)])
    }

    @Test func takesTheFramesSizeForMediaOfNoKnownSize() throws {
        let imported = try read(frame: CGSize(width: 1920, height: 1080), media: nil, center(0.25, -0.25))
        #expect(try position(imported).value == CGPoint(x: 0.75, y: 0.25))
    }
}
