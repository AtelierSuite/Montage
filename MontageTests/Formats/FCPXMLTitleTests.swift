import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

struct FCPXMLTitleTests {
    private static func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
        CMTime(value: value, timescale: timescale)
    }

    private static let red = RGBAColor(red: 1, green: 0, blue: 0)

    /// Mixed formatting, most of the style, a transform and an effect, on a
    /// title in the primary storyline and one connected to it.
    static func project() -> Project {
        var style = TextStyle(fontFamily: "Avenir Next", fontSize: 120, weight: .medium, isItalic: true)
        style.fill = LayerFill(style: .solid, color: RGBAColor(red: 1, green: 0.8, blue: 0.2))
        style.alignment = .leading
        style.letterSpacing = Animatable(4)
        style.lineSpacing = Animatable(10)
        style.outline = LayerStroke(isEnabled: true, color: .black, width: 6)
        style.shadow = LayerShadow(isEnabled: true, color: RGBAColor(white: 0, alpha: 0.5), blur: 8, offset: CGSize(width: 3, height: 4))
        let text = TextContent(runs: [
            TextRun("Big "), TextRun("bold", formatting: TextRun.Formatting(weight: .bold, isItalic: false)),
            TextRun(" and\nred", formatting: TextRun.Formatting(color: red)),
        ], style: style)
        var first = Clip(content: .text(text), sourceRange: CMTimeRange(start: .zero, duration: seconds(3)))
        first.transform.position = Animatable(CGPoint(x: 0.25, y: 0.75), keyframes: [
            Keyframe(time: .zero, value: CGPoint(x: 0.25, y: 0.75)), Keyframe(time: seconds(2), value: CGPoint(x: 0.5, y: 0.5)),
        ])
        first.transform.scale = Animatable(1.5)
        first.opacity = Animatable(0.8)

        var correction = ColorCorrection()
        correction.exposure = Animatable(0.5)
        var connected = Clip(content: .text(TextContent("Lower third")), sourceRange: CMTimeRange(start: .zero, duration: seconds(2)),
                             timelineStart: seconds(1))
        connected.effects = [Effect(.colorCorrection(correction))]
        let shape = Clip(content: .shape(ShapeContent()), sourceRange: CMTimeRange(start: .zero, duration: seconds(1)),
                         timelineStart: seconds(4))
        return Project(
            settings: ProjectSettings(renderSize: CGSize(width: 1920, height: 1080), frameDuration: seconds(1, 30)),
            tracks: [Track(kind: .video, clips: [first]), Track(kind: .video, clips: [connected, shape])]
        )
    }

    private func export(_ project: Project) -> Data {
        ProjectInterchange.fcpxml(for: project, named: "Titles", mediaResolver: MediaResolver { _ in nil })
    }

    // MARK: - Writing

    @Test func writesTextAsBasicTitles() throws {
        let project = Self.project()
        let root = try MarkupElement.parse(export(project))
        let effect = try #require(root.child("resources")?.children("effect").first { $0["name"] == "Basic Title" })
        #expect(effect["uid"] == FCPXMLTitles.basicTitleUID)
        let titles = root.allDescendants.filter { $0.name == "title" }
        #expect(titles.count == 2)
        #expect(titles.allSatisfy { $0["ref"] == effect["id"] })
        let first = try #require(titles.first)
        #expect(first["name"] == "Big bold and")
        #expect(first.child("text")?.children("text-style").map(\.text) == ["Big ", "bold", " and\nred"])
        // One definition for each formatting, named across the document.
        let definitions = root.allDescendants.filter { $0.name == "text-style-def" }.compactMap { $0["id"] }
        #expect(definitions == ["ts1", "ts2", "ts3", "ts4"])
        let bold = try #require(first.children("text-style-def").first { $0["id"] == "ts2" }?.child("text-style"))
        #expect(bold["fontFace"] == "Bold")
        #expect(bold["bold"] == "1")
        let plain = try #require(first.children("text-style-def").first?.child("text-style"))
        #expect(plain["font"] == "Avenir Next")
        #expect(plain["fontSize"] == "120")
        #expect(plain["fontFace"] == "Medium Italic")
        #expect(plain["fontColor"] == "1 0.8 0.2 1")
        #expect(plain["alignment"] == "left")
        #expect(plain["strokeWidth"] == "6")
        #expect(plain["shadowOffset"] == "5 306.869898")
        #expect(first.child("adjust-transform") != nil)
        #expect(first.child("adjust-blend")?["amount"] == "0.8")
        // Connected to the first, above it, with its effect.
        let connected = try #require(first.children("title").first)
        #expect(connected["lane"] == "1")
        #expect(connected["offset"] == "1s")
        #expect(connected.child("filter-video") != nil)
    }

    @Test func onlyShapesAreLeftOut() {
        let project = Self.project()
        let shape = project.tracks[1].clips[1].id
        #expect(ProjectInterchange.clipsLeftOutOfFCPXML(in: project) == [shape])
    }
}
