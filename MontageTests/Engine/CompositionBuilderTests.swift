import AVFoundation
import CoreGraphics
import CoreMedia
@testable import MontageEngine
import Testing

/// Sample media as the project's media items, with a resolver that finds
/// them in the samples folder.
private enum SampleMedia {
    static let landscape = MediaItem(
        name: "IMG_3311.mp4", kind: .video, location: .package(path: "IMG_3311.mp4"),
        metadata: MediaMetadata(
            duration: CMTime(value: 11250, timescale: 1000), naturalSize: CGSize(width: 1920, height: 1080),
            nominalFrameRate: 60, audioChannelCount: 2, audioSampleRate: 48000
        )
    )
    static let portrait = MediaItem(
        name: "IMG_3312.mp4", kind: .video, location: .package(path: "IMG_3312.mp4"),
        metadata: MediaMetadata(
            duration: CMTime(value: 9317, timescale: 1000), naturalSize: CGSize(width: 1080, height: 1920),
            nominalFrameRate: 60, audioChannelCount: 2, audioSampleRate: 48000
        )
    )
    /// H.264 at 29.97 with a spatial audio track that's turned off, and
    /// metadata tracks.
    static let withExtraTracks = MediaItem(
        name: "IMG_1805.MOV", kind: .video, location: .package(path: "IMG_1805.MOV"),
        metadata: MediaMetadata(
            duration: CMTime(value: 11930, timescale: 600), naturalSize: CGSize(width: 1920, height: 1080),
            nominalFrameRate: 29.97, audioChannelCount: 2, audioSampleRate: 48000
        )
    )
    static let image = MediaItem(
        name: "IMG_2459.JPG", kind: .image, location: .package(path: "IMG_2459.JPG"),
        metadata: MediaMetadata(naturalSize: CGSize(width: 4032, height: 3024))
    )
    static let all = [landscape, portrait, withExtraTracks, image]

    static let resolver = MediaResolver { item in
        guard case .package(let path) = item.location else { return nil }
        return Samples.url(path)
    }
}

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
    CMTimeRange(start: seconds(start), duration: seconds(duration))
}

private func project(_ tracks: [Track], media: [MediaItem] = SampleMedia.all) -> Project {
    Project(media: media, tracks: tracks)
}

private func build(_ project: Project, resolver: MediaResolver = SampleMedia.resolver) async throws -> BuiltComposition {
    try await CompositionBuilder(project: project, mediaResolver: resolver).build()
}

@Suite(.enabled(if: Samples.isAvailable, "Needs the sample media"))
struct CompositionBuilderTests {
    @Test func aWholeClipPlaysAsItIs() async throws {
        let clip = Clip(mediaID: SampleMedia.landscape.id, sourceRange: CMTimeRange(start: .zero, duration: SampleMedia.landscape.metadata.duration))
        let built = try await build(project([Track(kind: .video, clips: [clip])]))

        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")
        #expect(built.duration == SampleMedia.landscape.metadata.duration)
        #expect(built.composition.duration == built.duration)
        #expect(try await built.composition.loadTracks(withMediaType: .video).count == 1)
        #expect(try await built.composition.loadTracks(withMediaType: .audio).count == 1)
        #expect(built.videoLayers.map(\.segments.count) == [1])
        #expect(built.audioLayers.map(\.segments.first?.clipID) == [clip.id])

        let videoComposition = try #require(built.videoComposition)
        #expect(videoComposition.renderSize == CGSize(width: 1920, height: 1080))
        #expect(videoComposition.frameDuration == CMTime(value: 1, timescale: 30))
        #expect(videoComposition.instructions.count == 1)
        #expect(videoComposition.instructions.first?.timeRange == CMTimeRange(start: .zero, duration: built.duration))
    }

    @Test func trimsAndGapsLandWhereTheTimelineSays() async throws {
        let first = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(1, 2), timelineStart: .zero)
        let second = Clip(mediaID: SampleMedia.portrait.id, sourceRange: range(3, 2), timelineStart: seconds(4))
        let built = try await build(project([Track(kind: .video, clips: [first, second])]))

        #expect(built.duration == seconds(6))
        #expect(built.composition.duration == seconds(6))
        let video = try #require(try await built.composition.loadTracks(withMediaType: .video).first)
        let segments = video.segments.map { ($0.isEmpty, $0.timeMapping.target, $0.timeMapping.source) }
        #expect(segments.count == 3)
        #expect(segments[0].0 == false && segments[0].1 == range(0, 2) && segments[0].2 == range(1, 2))
        #expect(segments[1].0 == true && segments[1].1 == range(2, 2))
        #expect(segments[2].0 == false && segments[2].1 == range(4, 2) && segments[2].2 == range(3, 2))

        // An instruction each for the first clip, the gap and the second.
        let instructions = try #require(built.videoComposition).instructions
        #expect(instructions.map(\.timeRange) == [range(0, 2), range(2, 2), range(4, 2)])
        #expect(instructions.map { ($0 as? CompositorInstruction)?.layers.count } == [1, 0, 1])

        #expect(built.videoSegments(at: seconds(1)).map(\.segment.clipID) == [first.id])
        #expect(built.videoSegments(at: seconds(3)).isEmpty)
        #expect(built.videoSegments(at: seconds(5)).map(\.segment.sourceRange) == [range(3, 2)])
    }

    @Test func aTransitionShowsBothClipsHandlesOnALayerOfItsOwn() async throws {
        let first = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(1, 3))
        // Starting at the media's start, it has no frames before it: its first is held.
        let second = Clip(mediaID: SampleMedia.portrait.id, sourceRange: range(0, 3), timelineStart: seconds(3))
        var project = project([Track(kind: .video, clips: [first, second])])
        project.addTransition(from: first.id, to: second.id, duration: seconds(1))
        let built = try await build(project)

        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")
        #expect(built.duration == seconds(6))
        #expect(built.videoLayers.count == 2)
        let handles = built.videoLayers[1]
        #expect(handles.segments.map(\.clipID) == [second.id, first.id])
        #expect(handles.segments.map(\.timelineRange) == [range(2.5, 0.5), range(3, 0.5)])
        #expect(handles.segments.last?.sourceRange == range(4, 0.5))

        let tracks = try await built.composition.loadTracks(withMediaType: .video)
        let handleTrack = try #require(tracks.first { $0.trackID == handles.compositionTrackID })
        let pieces = handleTrack.segments.filter { !$0.isEmpty }.map { ($0.timeMapping.target, $0.timeMapping.source) }
        // The portrait's first frame held, then the landscape's media after its end.
        #expect(pieces.count == 2)
        #expect(pieces.first?.0 == range(2.5, 0.5))
        #expect(pieces.first?.1.start == .zero)
        #expect(pieces.last?.0 == range(3, 0.5))
        #expect(pieces.last?.1 == range(4, 0.5))

        let instructions = try #require(built.videoComposition).instructions.compactMap { $0 as? CompositorInstruction }
        #expect(instructions.map(\.timeRange) == [range(0, 2.5), range(2.5, 0.5), range(3, 0.5), range(3.5, 2.5)])
        #expect(instructions.map(\.layers.count) == [1, 2, 2, 1])
        for instruction in instructions[1...2] {
            #expect(instruction.layers.allSatisfy { $0.transition?.incomingClipID == second.id })
        }
        #expect(instructions[1].layers.map(\.clip.id) == [first.id, second.id])
        #expect(instructions[2].layers.map(\.clip.id) == [second.id, first.id])
        #expect(instructions[0].layers.first?.transition == nil)
    }

    @Test func aTransitionWithAClipLeftOutCuts() async throws {
        let first = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(1, 3))
        let missing = MediaItem(name: "missing.mp4", kind: .video, location: .package(path: "missing.mp4"), metadata: MediaMetadata())
        let second = Clip(mediaID: missing.id, sourceRange: range(0, 3), timelineStart: seconds(3))
        var project = project([Track(kind: .video, clips: [first, second])], media: SampleMedia.all + [missing])
        project.addTransition(from: first.id, to: second.id, duration: seconds(1))
        let built = try await build(project)
        #expect(built.videoLayers.count == 1)
    }

    @Test func aClipAtAnotherSpeedIsStretchedToItsLength() async throws {
        var slow = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(1, 2))
        slow.speed = try #require(ClipSpeed(media: 1, timeline: 2))
        let after = Clip(mediaID: SampleMedia.portrait.id, sourceRange: range(0, 1), timelineStart: seconds(4))
        let built = try await build(project([Track(kind: .video, clips: [slow, after])]))

        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")
        #expect(built.duration == seconds(5))
        let video = try #require(try await built.composition.loadTracks(withMediaType: .video).first)
        let pieces = video.segments.map { ($0.timeMapping.target, $0.timeMapping.source) }
        #expect(pieces.first?.0 == range(0, 4))
        #expect(pieces.first?.1 == range(1, 2))
        #expect(pieces.last?.0 == range(4, 1))
        #expect(built.videoLayers.first?.segments.first?.timelineRange == range(0, 4))
        #expect(built.videoLayers.first?.segments.first?.sourceRange == range(1, 2))
        // Its sound is stretched with it.
        let audio = try #require(try await built.composition.loadTracks(withMediaType: .audio).first)
        #expect(audio.segments.first?.timeMapping.target == range(0, 4))
    }

    @Test func layersStackFromTheBottomTrack() async throws {
        let bottom = Track(kind: .video, clips: [Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 4))])
        let top = Track(kind: .video, clips: [Clip(mediaID: SampleMedia.portrait.id, sourceRange: range(0, 2), timelineStart: seconds(1))])
        let built = try await build(project([bottom, top]))

        #expect(built.videoLayers.map(\.trackID) == [bottom.id, top.id])
        let instructions = try #require(built.videoComposition).instructions.compactMap { $0 as? CompositorInstruction }
        #expect(instructions.map(\.timeRange) == [range(0, 1), range(1, 2), range(3, 1)])
        let topID = built.videoLayers[1].compositionTrackID
        let bottomID = built.videoLayers[0].compositionTrackID
        #expect(instructions[1].layers.map(\.trackID) == [bottomID, topID])
        #expect(built.videoSegments(at: seconds(2)).map(\.layer.trackID) == [bottom.id, top.id])
    }

    @Test func hiddenTracksLeaveTheirPictureAndMutedTracksTheirSound() async throws {
        let clip = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 3))
        let hidden = try await build(project([Track(kind: .video, clips: [clip], isHidden: true)]))
        #expect(hidden.videoLayers.isEmpty)
        #expect(hidden.videoComposition == nil)
        #expect(hidden.audioLayers.count == 1)
        #expect(hidden.duration == seconds(3))

        let muted = try await build(project([Track(kind: .video, clips: [clip], isMuted: true)]))
        #expect(muted.videoLayers.count == 1)
        #expect(muted.audioLayers.isEmpty)
        #expect(muted.audioMix == nil)

        let both = try await build(project([Track(kind: .video, clips: [clip], isMuted: true, isHidden: true)]))
        #expect(both.isEmpty)
        #expect(both.duration == .zero)
    }

    @Test func detachedAudioPlaysOnlyFromItsOwnClip() async throws {
        let video = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 3), isAudioDetached: true)
        let audio = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 3), timelineStart: seconds(1))
        let audioTrack = Track(kind: .audio, clips: [audio])
        let built = try await build(project([Track(kind: .video, clips: [video]), audioTrack]))

        #expect(built.audioLayers.map(\.trackID) == [audioTrack.id])
        #expect(built.audioLayers.first?.segments.map(\.timelineRange) == [range(1, 3)])
        #expect(built.duration == seconds(4))
        #expect(try await built.composition.loadTracks(withMediaType: .audio).count == 1)
    }

    @Test func onlyTheMainAudioTrackIsUsed() async throws {
        let clip = Clip(mediaID: SampleMedia.withExtraTracks.id, sourceRange: range(0, 5))
        let built = try await build(project([Track(kind: .video, clips: [clip])]))

        let audio = try await built.composition.loadTracks(withMediaType: .audio)
        #expect(audio.count == 1)
        // The source's first track is the AAC one; the spatial audio one is off.
        #expect(audio.first?.segments.first?.sourceTrackID == 1)
        #expect(try await built.composition.loadTracks(withMediaType: .metadata).isEmpty)
    }

    @Test func missingMediaIsSkippedAndReported() async throws {
        let missing = Clip(mediaID: SampleMedia.portrait.id, sourceRange: range(0, 2))
        let present = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 2), timelineStart: seconds(2))
        let unknown = Clip(mediaID: UUID(), sourceRange: range(0, 1), timelineStart: seconds(4))
        let resolver = MediaResolver { item in
            item.id == SampleMedia.portrait.id ? Samples.url("Not There.mp4") : SampleMedia.resolver.url(for: item)
        }
        let built = try await build(project([Track(kind: .video, clips: [missing, present, unknown])]), resolver: resolver)

        #expect(built.skippedClips.map(\.clipID) == [missing.id, unknown.id])
        #expect(built.skippedClips.map(\.reason) == [.fileNotFound, .mediaNotInProject])
        #expect(built.missingMedia == [SampleMedia.portrait.id, unknown.mediaID!])
        // What's left out plays as empty time, so the clip after it keeps its
        // place; at the end, the composition stops with the last clip placed.
        #expect(built.videoLayers.first?.segments.map(\.timelineRange) == [range(2, 2)])
        #expect(built.duration == seconds(4))
        #expect(built.composition.duration == seconds(4))
        #expect(try #require(built.videoComposition).instructions.map(\.timeRange) == [range(0, 2), range(2, 2)])
    }

    @Test func aStillImageHoldsItsTimeForTheCompositor() async throws {
        let image = Clip(mediaID: SampleMedia.image.id, sourceRange: range(0, 3))
        let video = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 2), timelineStart: seconds(4))
        let built = try await build(project([Track(kind: .video, clips: [image, video])]))
        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")
        #expect(built.videoLayers.first?.segments.map(\.timelineRange) == [range(0, 3), range(4, 2)])
        #expect(built.duration == seconds(6))
        #expect(built.composition.duration == seconds(6))
        // A still has no sound of its own.
        #expect(built.audioLayers.first?.segments.map(\.clipID) == [video.id])
    }

    @Test func aStillImageAloneMakesAPicture() async throws {
        let image = Clip(mediaID: SampleMedia.image.id, sourceRange: range(0, 10))
        let built = try await build(project([Track(kind: .video, clips: [image])]))
        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")
        #expect(built.duration == seconds(10))
        #expect(built.composition.duration == seconds(10))
        #expect(built.audioLayers.isEmpty)
        #expect(try #require(built.videoComposition).instructions.map(\.timeRange) == [range(0, 10)])
    }

    @Test func textAfterTheLastVideoLengthensTheComposition() async throws {
        let video = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 2))
        let title = Clip(content: .text(TextContent("Fin")), sourceRange: range(0, 3), timelineStart: seconds(2))
        let built = try await build(project([Track(kind: .video, clips: [video, title])]))
        #expect(built.skippedClips.isEmpty)
        #expect(built.duration == seconds(5))
        #expect(built.composition.duration == seconds(5))
        let instructions = try #require(built.videoComposition).instructions
        #expect(instructions.map(\.timeRange) == [range(0, 2), range(2, 3)])
        #expect(built.videoSegments(at: seconds(3)).map(\.segment.clipID) == [title.id])
    }

    @Test(arguments: [false, true])
    func aTailRingsOnPastStillsAndText(text: Bool) async throws {
        // Two seconds of a still or a title, and a second and a half of sound
        // with a reverb that rings for 1.2 seconds after it.
        let picture = text
            ? Clip(content: .text(TextContent("Fin")), sourceRange: range(0, 2))
            : Clip(mediaID: SampleMedia.image.id, sourceRange: range(0, 2))
        var reverb = Reverb()
        reverb.room = .mediumRoom
        let sound = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(1, 1.5), effects: [Effect(.reverb(reverb))])
        let timeline = project([Track(kind: .video, clips: [picture]), Track(kind: .audio, clips: [sound])])
        let built = try await build(timeline)
        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")
        #expect(timeline.duration == seconds(2))
        #expect(built.duration == seconds(2.7))
        #expect(built.composition.duration == seconds(2.7))
        // The picture shows for its two seconds, then black under the tail.
        let instructions = try #require(built.videoComposition).instructions
        #expect(instructions.last?.timeRange.end == seconds(2.7))
        #expect(built.videoSegments(at: seconds(1)).map(\.segment.clipID) == [picture.id])
        #expect(built.videoSegments(at: seconds(2.4)).isEmpty)
        // Nothing here needs a copy made.
        #expect(DerivedMedia.allCases.allSatisfy { $0.media(neededIn: timeline).isEmpty })
    }

    @Test func textOnAnAudioTrackIsLeftOut() async throws {
        let title = Clip(content: .text(TextContent("Nope")), sourceRange: range(0, 3))
        let built = try await build(project([Track(kind: .audio, clips: [title])]))
        #expect(built.skippedClips.map(\.reason) == [.noUsableTrack])
        #expect(built.isEmpty)
    }

    @Test func aStillImageOnAnAudioTrackIsSkipped() async throws {
        let image = Clip(mediaID: SampleMedia.image.id, sourceRange: range(0, 3))
        let built = try await build(project([Track(kind: .audio, clips: [image])]))
        #expect(built.skippedClips.map(\.reason) == [.noUsableTrack])
        #expect(built.isEmpty)
    }

    @Test func aSourceRangePastTheMediaPlaysWhatThereIs() async throws {
        let clip = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(10, 4))
        let built = try await build(project([Track(kind: .video, clips: [clip])]))
        let segment = try #require(built.videoLayers.first?.segments.first)
        #expect(segment.timelineRange.start == .zero)
        #expect(segment.timelineRange.end == SampleMedia.landscape.metadata.duration - seconds(10))
        // The sound runs a little longer than the picture in this file.
        #expect(built.duration == built.audioLayers.first?.segments.first?.timelineRange.end)
        #expect(built.duration < seconds(4))
    }

    @Test func volumeKeyframesBecomeRamps() async throws {
        var clip = Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 4), timelineStart: seconds(1))
        clip.volume = Animatable(1, keyframes: [Keyframe(time: seconds(1), value: 1), Keyframe(time: seconds(3), value: 0)])
        let quiet = Clip(mediaID: SampleMedia.portrait.id, sourceRange: range(0, 2), timelineStart: seconds(6), volume: Animatable(0.5))
        let built = try await build(project([Track(kind: .audio, clips: [clip, quiet])]))

        let parameters = try #require(built.audioMix?.inputParameters.first)
        #expect(parameters.trackID == built.audioLayers.first?.compositionTrackID)
        var start: Float = 0, end: Float = 0, timeRange = CMTimeRange.zero
        #expect(parameters.getVolumeRamp(for: seconds(3), startVolume: &start, endVolume: &end, timeRange: &timeRange))
        #expect(start == 1 && end == 0 && timeRange == range(2, 2))
        #expect(parameters.getVolumeRamp(for: seconds(7), startVolume: &start, endVolume: &end, timeRange: &timeRange))
        #expect(start == 0.5)
    }

    @Test func framesRenderThroughTheVideoComposition() async throws {
        let clips = [
            Clip(mediaID: SampleMedia.landscape.id, sourceRange: range(0, 2)),
            Clip(mediaID: SampleMedia.portrait.id, sourceRange: range(2, 2), timelineStart: seconds(3)),
            Clip(mediaID: SampleMedia.withExtraTracks.id, sourceRange: range(5, 2), timelineStart: seconds(5)),
        ]
        let built = try await build(project([Track(kind: .video, clips: clips)]))

        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for time in [0.5, 3.5, 6.5] {
            let (image, _) = try await generator.image(at: seconds(time))
            #expect(image.width == 1920 && image.height == 1080)
        }
        // The gap between the first two clips is black.
        let (gap, _) = try await generator.image(at: seconds(2.5))
        #expect(brightness(of: gap, at: CGPoint(x: 960, y: 540)) < 0.02)
        // The portrait clip is fitted between black bars at the sides.
        let (pillarboxed, _) = try await generator.image(at: seconds(3.5))
        #expect(brightness(of: pillarboxed, at: CGPoint(x: 100, y: 540)) < 0.02)
    }

    /// How bright a pixel is, from 0 to 1.
    private func brightness(of image: CGImage, at point: CGPoint) -> Double {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: -point.x, y: -(CGFloat(image.height) - point.y), width: CGFloat(image.width), height: CGFloat(image.height)))
        return Double(Int(pixel[0]) + Int(pixel[1]) + Int(pixel[2])) / (3 * 255)
    }
}

struct LayerTransformTests {
    private let renderSize = CGSize(width: 1920, height: 1080)

    private func frame(of size: CGSize, preferredTransform: CGAffineTransform = .identity, clipTransform: ClipTransform = ClipTransform()) -> CGRect {
        let transform = CompositionBuilder.layerTransform(
            naturalSize: size, preferredTransform: preferredTransform, clipTransform: clipTransform,
            renderSize: renderSize, at: .zero
        )
        return CGRect(origin: .zero, size: size).applying(transform).integral
    }

    @Test func aMatchingPictureFillsTheFrame() {
        #expect(frame(of: renderSize) == CGRect(origin: .zero, size: renderSize))
        #expect(frame(of: CGSize(width: 3840, height: 2160)) == CGRect(origin: .zero, size: renderSize))
    }

    @Test func aRotatedPictureIsTurnedUprightAndFitted() {
        // A phone's portrait video: landscape frames turned a quarter clockwise.
        let rotated = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)
        #expect(frame(of: CGSize(width: 1920, height: 1080), preferredTransform: rotated)
            == CGRect(x: 656, y: 0, width: 608, height: 1080))
        // Stored upright already, it fits the same way.
        #expect(frame(of: CGSize(width: 1080, height: 1920)) == CGRect(x: 656, y: 0, width: 608, height: 1080))
    }

    @Test func theClipTransformScalesAndMovesThePicture() {
        var transform = ClipTransform()
        transform.scale = Animatable(0.5)
        transform.position = Animatable(CGPoint(x: 0.25, y: 0.25))
        #expect(frame(of: renderSize, clipTransform: transform) == CGRect(x: 0, y: 0, width: 960, height: 540))
    }
}

struct ParameterRampTests {
    @Test func aConstantParameterHasNoRamps() {
        #expect(Animatable(0.5).ramps(over: range(0, 4), clipStart: .zero).isEmpty)
    }

    @Test func linearKeyframesRampInTimelineTime() {
        let value = Animatable(0.0, keyframes: [Keyframe(time: seconds(1), value: 0), Keyframe(time: seconds(2), value: 1)])
        let ramps = value.ramps(over: range(10, 4), clipStart: seconds(10))
        #expect(ramps == [
            ParameterRamp(timeRange: range(10, 1), start: 0, end: 0),
            ParameterRamp(timeRange: range(11, 1), start: 0, end: 1),
            ParameterRamp(timeRange: range(12, 2), start: 1, end: 1),
        ])
    }

    @Test func easedKeyframesAreCutIntoPieces() {
        let value = Animatable(0.0, keyframes: [
            Keyframe(time: .zero, value: 0, interpolation: .easeInOut), Keyframe(time: seconds(1), value: 1),
        ])
        let ramps = value.ramps(over: range(0, 1), clipStart: .zero)
        #expect(ramps.count == Animatable<Double>.easedPieces)
        #expect(ramps.first?.start == 0 && ramps.last?.end == 1)
        #expect(ramps.last?.timeRange.end == seconds(1))
    }
}
