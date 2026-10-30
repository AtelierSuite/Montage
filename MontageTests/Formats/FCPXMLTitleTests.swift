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
        style.fontSize = Animatable(120, keyframes: [
            Keyframe(time: .zero, value: 120, interpolation: .easeOut), Keyframe(time: seconds(1), value: 150),
        ])
        style.outline.width = Animatable(6, keyframes: [Keyframe(time: .zero, value: 6), Keyframe(time: seconds(2), value: 2)])
        style.background = TextBackground(isEnabled: true, color: RGBAColor(white: 0, alpha: 0.5), padding: 30, cornerRadius: 8)
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
        var lowerStyle = TextStyle()
        lowerStyle.fill = LayerFill(style: .linearGradient, color: red, endColor: RGBAColor(red: 0, green: 0, blue: 1), angle: 90)
        var connected = Clip(content: .text(TextContent("Lower third", style: lowerStyle)),
                             sourceRange: CMTimeRange(start: .zero, duration: seconds(2)),
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

    private func texts(in imported: ImportedProject) -> [(clip: Clip, text: TextContent)] {
        imported.project.tracks.flatMap(\.clips).compactMap { clip in clip.content.text.map { (clip, $0) } }
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
        #expect(plain["backgroundColor"] == "0 0 0 0.5")
        #expect(first.child("adjust-transform") != nil)
        #expect(first.child("adjust-blend")?["amount"] == "0.8")
        // Connected to the first, above it, with its effect.
        let connected = try #require(first.children("title").first)
        #expect(connected["lane"] == "1")
        #expect(connected["offset"] == "1s")
        #expect(connected.child("filter-video") != nil)
    }

    @Test func writesKeyframedFormattingAsTextStyleParams() throws {
        let root = try MarkupElement.parse(export(Self.project()))
        let first = try #require(root.allDescendants.first { $0.name == "title" })
        let plain = try #require(first.children("text-style-def").first?.child("text-style"))
        // The size, as the Motion text style's own Size.
        let size = try #require(plain.children("param").first { $0["key"] == "3" })
        #expect(size["name"] == "Size")
        #expect(size["value"] == "120")
        let sizes = size.child("keyframeAnimation")?.children("keyframe") ?? []
        #expect(sizes.map { $0["time"] } == ["0s", "1s"])
        #expect(sizes.map { $0["value"] } == ["120", "150"])
        #expect(sizes.first?["interp"] == "easeOut")
        // The outline's width, inside the Outline's settings.
        let outline = try #require(plain.children("param").first { $0["key"] == "30" })
        let width = try #require(outline.children("param").first { $0["key"] == "36" })
        #expect(width.child("keyframeAnimation")?.children("keyframe").map { $0["value"] } == ["6", "2"])
        #expect(outline.children("param").first { $0["key"] == "32" }?["value"] == "0 0 0")
        // The shadow has no keyframes, so the attributes say all of it.
        #expect(!plain.children("param").contains { $0["key"] == "21" })
    }

    @Test func writesGradientFills() throws {
        let root = try MarkupElement.parse(export(Self.project()))
        let lower = try #require(root.allDescendants.first { $0.name == "title" && $0["name"] == "Lower third" })
        let id = try #require(lower.child("text")?.children("text-style").first?["ref"])
        let style = try #require(root.allDescendants.first { $0.name == "text-style-def" && $0["id"] == id }?.child("text-style"))
        // The first colour for anything that reads only the attributes.
        #expect(style["fontColor"] == "1 0 0 1")
        let face = try #require(style.children("param").first { $0["key"] == "14" })
        #expect(face.children("param").first { $0["key"] == "15" }?["value"] == "1 (Gradient)")
        let gradient = try #require(face.children("param").first { $0["key"] == "17" })
        let ends = gradient.children("param").first { $0["key"] == "1" }?.children("param") ?? []
        #expect(ends.map { $0["key"] } == ["999140132", "999140133"])
        #expect(ends.map { $0.child("param")?["value"] } == ["1 0 0", "0 0 1"])
        #expect(gradient.children("param").first { $0["key"] == "3" }?["value"] == "0 (Linear)")
        // Top to bottom: pointing down, with y running up.
        #expect(gradient.children("param").first { $0["key"] == "4" }?["value"] == "-1.570796")
    }

    @Test func shapesAndEmptyTextAreLeftOut() throws {
        var project = Self.project()
        let shape = project.tracks[1].clips[1].id
        #expect(ProjectInterchange.clipsLeftOutOfFCPXML(in: project) == [shape])
        // Text with no words would show Final Cut's own, so it goes too:
        // as a gap on the storyline, and not at all connected.
        let empty = Clip(content: .text(TextContent()), sourceRange: CMTimeRange(start: .zero, duration: Self.seconds(1)),
                         timelineStart: Self.seconds(3))
        let connected = Clip(content: .text(TextContent()), sourceRange: CMTimeRange(start: .zero, duration: Self.seconds(1)),
                             timelineStart: Self.seconds(6))
        project.tracks[0].insert(empty)
        project.tracks[1].insert(connected)
        #expect(Set(ProjectInterchange.clipsLeftOutOfFCPXML(in: project)) == [shape, empty.id, connected.id])
        let root = try MarkupElement.parse(export(project))
        #expect(root.allDescendants.filter { $0.name == "title" }.count == 2)
        let spine = try #require(root.allDescendants.first { $0.name == "spine" })
        #expect(spine.children.map(\.name) == ["title", "gap", "gap"])
        #expect(!root.allDescendants.contains { $0.name == "gap" && $0["lane"] != nil })
    }

    @Test func titlesComeBackAsTheTextTheyWere() throws {
        let project = Self.project()
        let imported = try ProjectInterchange.read(export(project))
        let back = texts(in: imported)
        let originals = project.tracks.flatMap(\.clips).compactMap { clip in clip.content.text.map { (clip, $0) } }
        #expect(back.count == originals.count)
        for (original, copy) in zip(originals, back) {
            // Exactly, from Montage's own copy in the title's metadata.
            #expect(copy.text == original.1)
            #expect(copy.text.runs == original.1.runs)
            #expect(copy.clip.timelineRange == original.0.timelineRange)
            let style = copy.text.style, expected = original.1.style
            #expect(style.fontFamily == expected.fontFamily)
            #expect(style.fontSize.value == expected.fontSize.value)
            #expect(style.weight == expected.weight)
            #expect(style.isItalic == expected.isItalic)
            #expect(style.fill.color.value == expected.fill.color.value)
            #expect(style.alignment == expected.alignment)
            #expect(style.letterSpacing.value == expected.letterSpacing.value)
            #expect(style.lineSpacing.value == expected.lineSpacing.value)
            #expect(style.outline.isEnabled == expected.outline.isEnabled)
            #expect(style.shadow.isEnabled == expected.shadow.isEnabled)
            if expected.shadow.isEnabled {
                #expect(abs(style.shadow.offset.value.width - expected.shadow.offset.value.width) < 0.0001)
                #expect(abs(style.shadow.offset.value.height - expected.shadow.offset.value.height) < 0.0001)
                #expect(style.shadow.blur.value == expected.shadow.blur.value)
            }
            #expect(copy.clip.opacity == original.0.opacity)
            #expect(copy.clip.transform.scale == original.0.transform.scale)
            let positions = zip(copy.clip.transform.position.keyframes, original.0.transform.position.keyframes)
            #expect(copy.clip.transform.position.keyframes.count == original.0.transform.position.keyframes.count)
            for (a, b) in positions {
                #expect(a.time == b.time)
                #expect(abs(a.value.x - b.value.x) < 0.00001 && abs(a.value.y - b.value.y) < 0.00001)
            }
            #expect(copy.clip.effects.count == original.0.effects.count)
        }
        // On a track above the first title, as it was connected above it.
        let lower = try #require(imported.project.tracks.firstIndex { $0.clips.contains { $0.content.text?.string == "Lower third" } })
        let big = try #require(imported.project.tracks.firstIndex { $0.clips.contains { $0.content.text?.string.hasPrefix("Big") == true } })
        #expect(lower > big)
        #expect(imported.report.isEmpty)
    }

    // MARK: - Reading Final Cut's

    /// Titles as Final Cut writes them: from an hour into their own time, a
    /// style defined in one title and used in the next, a Basic Title moved
    /// by its own Position, and a title of another template.
    private static let finalCutTitles = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE fcpxml>
    <fcpxml version="1.11">
        <resources>
            <format id="r1" name="FFVideoFormat1080p30" frameDuration="100/3000s" width="1920" height="1080" colorSpace="1-1-1 (Rec. 709)"/>
            <effect id="r2" name="Basic Title" uid=".../Titles.localized/Bumper:Opener.localized/Basic Title.localized/Basic Title.moti"/>
            <effect id="r3" name="Lower Third" uid=".../Titles.localized/Lower Thirds.localized/Lower Third.localized/Lower Third.moti"/>
        </resources>
        <library>
            <event name="Titles">
                <project name="Titles">
                    <sequence format="r1" duration="10s" tcStart="0s" tcFormat="NDF" audioLayout="stereo" audioRate="48k">
                        <spine>
                            <title ref="r2" offset="0s" name="Hello world - Basic Title" start="3600s" duration="5s">
                                <param name="Position" key="9999/999166631/999166633/1/100/101" value="0 -270"/>
                                <param name="Flatten" key="9999/999166631/999166633/2/351" value="1"/>
                                <param name="Alignment" key="9999/999166631/999166633/2/354/999169573/401" value="1 (Center)"/>
                                <text>
                                    <text-style ref="ts1">Hello </text-style>
                                    <text-style ref="ts2">world</text-style>
                                </text>
                                <text-style-def id="ts1">
                                    <text-style font="Helvetica" fontSize="63" fontFace="Regular" fontColor="1 1 1 1" alignment="center"/>
                                </text-style-def>
                                <text-style-def id="ts2">
                                    <text-style font="Helvetica" fontSize="63" fontFace="Bold Oblique" fontColor="1 0 0 1" alignment="center"/>
                                </text-style-def>
                                <adjust-transform position="0 0" scale="1 1">
                                    <param name="scale">
                                        <keyframeAnimation>
                                            <keyframe time="3600s" value="1 1"/>
                                            <keyframe time="3602s" value="2 2"/>
                                        </keyframeAnimation>
                                    </param>
                                </adjust-transform>
                            </title>
                            <title ref="r2" offset="5s" name="Again" start="3600s" duration="2s">
                                <text>
                                    <text-style ref="ts1">Again</text-style>
                                </text>
                                <text>
                                    <text-style ref="ts3">underlined</text-style>
                                </text>
                                <text-style-def id="ts3">
                                    <text-style font="Helvetica" fontSize="40" fontFace="Regular" underline="1"/>
                                </text-style-def>
                            </title>
                            <title ref="r3" offset="7s" name="Jane Doe" start="3600s" duration="3s">
                                <param name="Line 1" key="9999/10003/1/100" value="1"/>
                                <text>
                                    <text-style ref="ts4">Jane Doe</text-style>
                                </text>
                                <text-style-def id="ts4">
                                    <text-style font="Futura" fontSize="50" fontFace="Medium" fontColor="0 0 0 1" strokeColor="1 1 1 1" strokeWidth="2"/>
                                </text-style-def>
                            </title>
                        </spine>
                    </sequence>
                </project>
            </event>
        </library>
    </fcpxml>
    """

    @Test func readsFinalCutsTitles() throws {
        let imported = try ProjectInterchange.read(Data(Self.finalCutTitles.utf8))
        let titles = texts(in: imported)
        #expect(titles.map(\.text.string) == ["Hello world", "Again\nunderlined", "Jane Doe"])

        let hello = try #require(titles.first)
        #expect(hello.clip.timelineRange == CMTimeRange(start: .zero, duration: Self.seconds(5)))
        #expect(hello.text.style.fontFamily == "Helvetica")
        #expect(hello.text.style.fontSize.value == 63)
        #expect(hello.text.style.weight == .regular)
        #expect(hello.text.style.fill.color.value == .white)
        #expect(hello.text.runs == [
            TextRun("Hello "),
            TextRun("world", formatting: TextRun.Formatting(weight: .bold, isItalic: true, color: Self.red)),
        ])
        // A quarter of the frame's height below its centre.
        #expect(hello.clip.transform.position.value == CGPoint(x: 0.5, y: 0.75))
        // Keyframes from the title's own start, an hour in.
        #expect(hello.clip.transform.scale.keyframes.map(\.time) == [.zero, Self.seconds(2)])

        // A style from the title before.
        let again = titles[1]
        #expect(again.text.style.fontSize.value == 63)

        let lower = titles[2]
        #expect(lower.text.style.fontFamily == "Futura")
        #expect(lower.text.style.weight == .medium)
        #expect(lower.text.style.fill.color.value == .black)
        #expect(lower.text.style.outline.isEnabled)
        #expect(lower.text.style.outline.width.value == 2)

        let issues = imported.report.items.map(\.issue)
        #expect(issues.contains(.titleTemplate(name: "Lower Third")))
        #expect(issues.contains(.setting(name: "Underline")))
        #expect(issues.contains(.setting(name: "Text style per word")))
        // The Basic Title's own settings it understands aren't reported, and
        // nothing is left out.
        #expect(!issues.contains(.setting(name: "Flatten")))
        #expect(!issues.contains { $0 == .title })
        #expect(issues.count == 3)
    }

    @Test func titlesChangedInFinalCutAreReadAsTheyAre() throws {
        // Montage's copy no longer agrees with the size Final Cut wrote.
        let xml = String(decoding: export(Self.project()), as: UTF8.self)
            .replacingOccurrences(of: "fontSize=\"120\"", with: "fontSize=\"90\"")
        let imported = try ProjectInterchange.read(Data(xml.utf8))
        let big = try #require(texts(in: imported).first { $0.text.string.hasPrefix("Big") })
        #expect(big.text.style.fontSize.value == 90)
        #expect(big.text.style.background.isEnabled)
        #expect(big.text.style.background.color.value == RGBAColor(white: 0, alpha: 0.5))
        #expect(imported.report.items.contains { $0.issue == .setting(name: "Text style animation") })
    }

    @Test func aTitleWithNoWordsIsReported() throws {
        let xml = Self.finalCutTitles.replacingOccurrences(of: "<text-style ref=\"ts4\">Jane Doe</text-style>", with: "")
        let imported = try ProjectInterchange.read(Data(xml.utf8))
        #expect(texts(in: imported).count == 2)
        #expect(imported.report.items.contains { $0.issue == .title && $0.time == Self.seconds(7) })
    }

    @Test func facesNameTheirWeightAndSlant() {
        #expect(FCPXMLTitles.fontFace("Condensed Bold Italic") == (.bold, true))
        #expect(FCPXMLTitles.fontFace("SemiBold") == (.semibold, false))
        #expect(FCPXMLTitles.fontFace("UltraLight") == (.ultraLight, false))
        #expect(FCPXMLTitles.fontFace("Regular") == (.regular, false))
        for weight in FontWeight.allCases {
            for isItalic in [false, true] {
                #expect(FCPXMLTitles.fontFace(FCPXMLTitles.fontFace(weight: weight, isItalic: isItalic)) == (weight, isItalic))
            }
        }
    }
}
