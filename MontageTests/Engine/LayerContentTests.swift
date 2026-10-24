import CoreGraphics
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

private func s(_ seconds: Int64) -> CMTime {
    CMTime(value: seconds, timescale: 1)
}

private func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
    CMTimeRange(start: s(start), duration: s(duration))
}

/// Clips of text, shapes and stills: how they're saved, edited and trimmed.
struct LayerContentTests {
    // MARK: - Saving

    @Test func aClipSavedBeforeContentTypesOpensAsMedia() throws {
        let media = UUID()
        let saved = Clip(mediaID: media, sourceRange: range(0, 2))
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])
        object["content"] = nil
        object["fit"] = nil
        object["mediaID"] = media.uuidString
        let clip = try JSONDecoder().decode(Clip.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(clip.content == .media(media))
        #expect(clip.fit == .fit)
        #expect(clip.mediaID == media)
    }

    @Test func mediaClipsStillNameTheirMediaForOlderBuilds() throws {
        let media = UUID()
        let data = try JSONEncoder().encode(Clip(mediaID: media, sourceRange: range(0, 2)))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mediaID"] as? String == media.uuidString)
        let text = try JSONEncoder().encode(Clip(content: .text(TextContent("A")), sourceRange: range(0, 2)))
        #expect((try JSONSerialization.jsonObject(with: text) as? [String: Any])?["mediaID"] == nil)
    }

    @Test func clipsOfStillsSavedAsMediaOpenAsImages() throws {
        let image = MediaItem(name: "Still.png", kind: .image, location: .package(path: "Media/Still.png"), metadata: MediaMetadata())
        let video = MediaItem(name: "Clip.mov", kind: .video, location: .package(path: "Media/Clip.mov"), metadata: MediaMetadata(duration: s(10)))
        let project = Project(media: [image, video], tracks: [Track(kind: .video, clips: [
            Clip(mediaID: image.id, sourceRange: range(0, 5)),
            Clip(mediaID: video.id, sourceRange: range(0, 5), timelineStart: s(5)),
        ])])
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded.tracks[0].clips.map(\.content) == [.image(image.id), .media(video.id)])
    }

    @Test func textAndShapesGoThereAndBack() throws {
        var text = TextContent(runs: [TextRun("Hello "), TextRun("world", formatting: .init(weight: .black, color: .black))])
        text.style.fontSize = Animatable(80, keyframes: [Keyframe(time: .zero, value: 80), Keyframe(time: s(2), value: 120)])
        text.style.shadow.isEnabled = true
        text.style.fill = LayerFill(style: .linearGradient, color: .white, endColor: .black, angle: 45)
        var shape = ShapeContent.defaults(for: .star)
        shape.stroke = LayerStroke(isEnabled: true, color: .white, width: 6, dash: .dashed, cap: .square, join: .bevel)
        let project = Project(tracks: [Track(kind: .video, clips: [
            Clip(content: .text(text), sourceRange: range(0, 5)),
            Clip(content: .shape(shape), sourceRange: range(0, 5), timelineStart: s(5), fit: .fill),
        ])])
        let decoded = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(project))
        #expect(decoded == project)
        #expect(decoded.tracks[0].clips[0].mediaID == nil)
    }

    // MARK: - Mixed formatting

    @Test func editingTheWordsKeepsTheirFormatting() {
        var text = TextContent(runs: [TextRun("Big "), TextRun("bold", formatting: .init(weight: .bold)), TextRun(" news")])
        // Typing inside the bold word makes more bold.
        text.replaceString(with: "Big boooold news")
        #expect(text.runs == [TextRun("Big "), TextRun("boooold", formatting: .init(weight: .bold)), TextRun(" news")])
        // Taking the bold word away leaves the rest as it was.
        text.replaceString(with: "Big news")
        #expect(text.runs == [TextRun("Big news")])
        #expect(text.string == "Big news")
    }

    @Test func formattingARangeSplitsTheRuns() {
        var text = TextContent("One two three")
        text.format(4..<7) { $0.isItalic = true; $0.color = .black }
        #expect(text.runs.map(\.text) == ["One ", "two", " three"])
        #expect(text.runs[1].formatting == TextRun.Formatting(isItalic: true, color: .black))
        #expect(text.formatting(in: 4..<7).isItalic == true)
        #expect(text.formatting(in: 0..<7).isItalic == nil)
        text.format(0..<13) { $0 = TextRun.Formatting() }
        #expect(text.runs == [TextRun("One two three")])
    }

    // MARK: - Trimming

    private func project(_ content: ClipContent) -> Project {
        Project(tracks: [Track(kind: .video, clips: [Clip(content: content, sourceRange: range(0, 5), timelineStart: s(2))])])
    }

    @Test func textCanBeTrimmedToAnyLength() {
        var project = project(.text(TextContent("Title")))
        let id = project.tracks[0].clips[0].id
        #expect(project.trimClip(id, edge: .end, to: s(600)) == s(600))
        #expect(project.tracks[0].clips[0].duration == s(598))
        // Its start can go back to the timeline's, though it has no media
        // before it.
        #expect(project.trimClip(id, edge: .start, to: s(0)) == .zero)
        #expect(project.tracks[0].clips[0].timelineRange == CMTimeRange(start: .zero, end: s(600)))
        #expect(project.tracks[0].clips[0].sourceRange.start == .zero)
    }

    @Test func shapesRollAndRippleWithoutMedia() {
        var project = project(.shape(ShapeContent()))
        let id = project.tracks[0].clips[0].id
        #expect(project.trimClip(id, edge: .start, to: s(3), style: .ripple) == s(3))
        #expect(project.tracks[0].clips[0].timelineRange == range(2, 4))
        #expect(project.trimClip(id, edge: .start, to: s(-5), style: .ripple) != nil)
        #expect(project.tracks[0].clips[0].duration == s(11))
    }

    @Test func splittingTextKeepsItsAnimationInPlace() throws {
        var text = TextContent("Grow")
        text.style.fontSize = Animatable(50, keyframes: [Keyframe(time: .zero, value: 50), Keyframe(time: s(4), value: 150)])
        var project = project(.text(text))
        let id = project.tracks[0].clips[0].id
        let split = project.splitClip(id, at: s(4))
        let after = try #require(split)
        let second = try #require(project.clip(id: after)?.clip)
        // Two seconds into the clip, the size is halfway; the second part
        // starts there.
        let size = second.content.text?.style.fontSize
        #expect(size?.value(at: .zero) == 100)
        #expect(size?.value(at: s(2)) == 150)
    }

    // MARK: - Adding

    @Test func addedTextGoesOverTheVideoUnderIt() {
        var fixture = TimelineFixture([(0, 0, 10)])
        let id = fixture.project.insertClip(of: .text(TextContent("Hi")), at: s(3))
        #expect(fixture.project.tracks.count == 2)
        #expect(fixture.project.tracks[1].clip(id: id)?.timelineRange == CMTimeRange(start: s(3), duration: Project.defaultImageDuration))
        // Another, later, goes on the same track where there's room.
        let next = fixture.project.insertClip(of: .shape(ShapeContent()), at: s(8))
        #expect(fixture.project.tracks.count == 2)
        #expect(fixture.project.tracks[1].clip(id: next) != nil)
        // One over the first goes above it.
        let over = fixture.project.insertClip(of: .shape(ShapeContent()), at: s(4))
        #expect(fixture.project.tracks.count == 3)
        #expect(fixture.project.tracks[2].clip(id: over) != nil)
    }

    @Test func addedLayersPassOverHiddenTracks() {
        var fixture = TimelineFixture([(0, 0, 10)])
        fixture.project.tracks.append(Track(kind: .video, isHidden: true))
        let id = fixture.project.insertClip(of: .text(TextContent("Hi")), at: s(3))
        #expect(fixture.project.tracks.count == 3)
        #expect(fixture.project.tracks[1].clips.isEmpty)
        #expect(fixture.project.tracks[2].clip(id: id) != nil)
    }

    @Test func shapesTurnedIntoLinesAndBackStayVisible() {
        var shape = ShapeContent.defaults(for: .rectangle)
        shape.changeKind(to: .line)
        #expect(shape.size.value == CGSize(width: 600, height: 0))
        #expect(shape.stroke.isEnabled)
        shape.changeKind(to: .star)
        #expect(shape.size.value.height > 0)
        #expect(shape.fill.style == .solid)
        // Between kinds that aren't lines, the look stays.
        shape.fill.style = .radialGradient
        shape.changeKind(to: .ellipse)
        #expect(shape.fill.style == .radialGradient)
    }

    @Test func kenBurnsZoomsAcrossTheWholeClip() {
        var clip = Clip(content: .image(UUID()), sourceRange: range(0, 6))
        clip.applyKenBurns(zoom: 1.2)
        #expect(clip.hasKenBurns)
        #expect(clip.transform.scale.value(at: .zero) == 1)
        #expect(abs(clip.transform.scale.value(at: s(6)) - 1.2) < 0.0001)
        #expect(clip.transform.position.value(at: s(6)) == CGPoint(x: 0.5, y: 0.5))
        clip.removeKenBurns()
        #expect(!clip.hasKenBurns)
        #expect(clip.transform.scale == Animatable(1))
    }

    @Test func presetsSetTheStyleAndPlace() throws {
        var clip = Clip(content: .text(TextContent("Name")), sourceRange: range(0, 5))
        let lowerThird = BuiltInTextPreset.lowerThird
        clip.apply(lowerThird.style, position: lowerThird.position)
        #expect(clip.content.text?.style == lowerThird.style)
        #expect(clip.transform.position.value == lowerThird.position)
        // A saved preset keeps the look at a time, without keyframes.
        clip.content = .text({
            var text = clip.content.text!
            text.style.fontSize = Animatable(10, keyframes: [Keyframe(time: .zero, value: 10), Keyframe(time: s(2), value: 30)])
            return text
        }())
        let preset = try #require(TextPreset(name: "Mine", from: clip, at: s(1)))
        #expect(preset.style.fontSize == Animatable(20))
        #expect(preset.position == lowerThird.position)
    }

    @Test func restylingTextDoesNotRebuildTheComposition() {
        let old = project(.text(TextContent("A")))
        var new = old
        new.tracks[0].update(old.tracks[0].clips[0].id) { clip in
            var text = clip.content.text!
            text.replaceString(with: "B")
            text.style.fontSize = Animatable(10)
            clip.content = .text(text)
            clip.fit = .fill
        }
        #expect(!PlaybackController.needsRebuild(from: old, to: new))
        var shape = old
        shape.tracks[0].update(old.tracks[0].clips[0].id) { $0.content = .shape(ShapeContent()) }
        #expect(PlaybackController.needsRebuild(from: old, to: shape))
    }
}
