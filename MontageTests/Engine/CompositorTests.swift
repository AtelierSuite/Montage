import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
@testable import MontageEngine
import Testing

/// Frames drawn by the custom compositor, checked pixel by pixel against
/// frames of the same media drawn alone.
@Suite(.enabled(if: Samples.isAvailable, "Needs the sample media"))
struct CompositorTests {
    private let landscape = MediaItem(name: "IMG_3311.mp4", kind: .video, location: .package(path: "IMG_3311.mp4"), metadata: MediaMetadata())
    private let portrait = MediaItem(name: "IMG_3312.mp4", kind: .video, location: .package(path: "IMG_3312.mp4"), metadata: MediaMetadata())
    /// Finds samples by name, and other files by their full path.
    private let resolver = MediaResolver { item in
        guard case .package(let path) = item.location else { return nil }
        return path.hasPrefix("/") ? URL(fileURLWithPath: path) : Samples.url(path)
    }
    /// Points inside the portrait picture, which is fitted into the middle
    /// of the frame between x 656 and 1264.
    private let points = [CGPoint(x: 960, y: 300), CGPoint(x: 960, y: 540), CGPoint(x: 800, y: 800), CGPoint(x: 1150, y: 950)]
    /// The time frames are taken at: a second into clips that start at zero.
    private let time = seconds(1)

    private func clip(_ media: MediaItem, _ change: (inout Clip) -> Void = { _ in }) -> Clip {
        var clip = Clip(mediaID: media.id, sourceRange: range(2, 3))
        change(&clip)
        return clip
    }

    private func frame(_ clips: [Clip], media: [MediaItem]? = nil, at time: CMTime? = nil) async throws -> FramePixels {
        let project = Project(media: media ?? [landscape, portrait], tracks: clips.map { Track(kind: .video, clips: [$0]) })
        let built = try await CompositionBuilder(project: project, mediaResolver: resolver).build()
        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")
        return try await render(built, at: time ?? self.time)
    }

    @Test func aLoneClipKeepsItsColours() async throws {
        let composed = try await frame([clip(landscape)])
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: Samples.url("IMG_3311.mp4")))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let source = FramePixels(try await generator.image(at: seconds(3)).image)
        for point in points + [CGPoint(x: 100, y: 100), CGPoint(x: 1800, y: 1000)] {
            #expect(composed.isClose(composed[point], source[point], within: 0.03), "\(point)")
        }
    }

    @Test func aClipsEffectsAreDrawnIntoTheFrame() async throws {
        let plain = try await frame([clip(landscape)])
        var darker = ColorCorrection()
        darker.exposure = Animatable(-2)
        let corrected = try await frame([clip(landscape) { $0.effects = [Effect(.colorCorrection(darker))] }])
        let turnedOff = try await frame([clip(landscape) { $0.effects = [Effect(isEnabled: false, .colorCorrection(darker))] }])
        for point in points {
            // Two stops down is about a quarter of the light, well under half.
            #expect(corrected.brightness(at: point) < plain.brightness(at: point) * 0.5, "\(point)")
            #expect(turnedOff.isClose(turnedOff[point], plain[point], within: 0.03), "\(point)")
        }
    }

    @Test func anOverlayIsFadedByItsOpacity() async throws {
        let bottom = try await frame([clip(landscape)])
        let top = try await frame([clip(portrait)])
        let both = try await frame([clip(landscape), clip(portrait) { $0.opacity = Animatable(0.5) }])
        for point in points {
            #expect(both.isClose(both[point], (bottom[point] + top[point]) / 2, within: 0.04), "\(point)")
        }
        // Beside the portrait picture, only the bottom layer shows.
        let side = CGPoint(x: 200, y: 540)
        #expect(both.isClose(both[side], bottom[side], within: 0.03))
    }

    @Test func aFadedLayerOverNothingFadesToBlack() async throws {
        let alone = try await frame([clip(landscape)])
        let faded = try await frame([clip(landscape) { $0.opacity = Animatable(0.5) }])
        for point in points {
            #expect(faded.isClose(faded[point], alone[point] / 2, within: 0.03), "\(point)")
        }
    }

    @Test func keyframedOpacityIsFollowedFrameByFrame() async throws {
        let bottom = try await frame([clip(landscape)])
        let top = try await frame([clip(portrait)])
        // From clear at the clip's start to opaque two seconds in: halfway at one.
        let fading = clip(portrait) {
            $0.opacity = Animatable(1, keyframes: [Keyframe(time: .zero, value: 0), Keyframe(time: seconds(2), value: 1)])
        }
        let both = try await frame([clip(landscape), fading])
        for point in points {
            #expect(both.isClose(both[point], (bottom[point] + top[point]) / 2, within: 0.04), "\(point)")
        }
    }

    @Test func aCrossDissolveMixesTheTwoClips() async throws {
        // A 2-second dissolve over the cut at 3s, between the landscape
        // from 2s and the portrait from 2s.
        let outgoing = clip(landscape)
        let incoming = clip(portrait) { $0.timelineStart = seconds(3) }
        var project = Project(media: [landscape, portrait], tracks: [Track(kind: .video, clips: [outgoing, incoming])])
        project.addTransition(from: outgoing.id, to: incoming.id, duration: seconds(2))
        let built = try await CompositionBuilder(project: project, mediaResolver: resolver).build()
        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")

        // At the cut, halfway: the landscape at 5s, past its end, and the
        // portrait at its start.
        let mixed = try await render(built, at: seconds(3))
        let after = try await frame([Clip(mediaID: landscape.id, sourceRange: range(4, 3))])
        let start = try await frame([Clip(mediaID: portrait.id, sourceRange: range(1, 3))])
        for point in points {
            #expect(mixed.isClose(mixed[point], (after[point] + start[point]) / 2, within: 0.05), "\(point)")
        }
        // A quarter of the way in: the landscape at 4.5s, the portrait at 1.5s from before its start.
        let early = try await render(built, at: seconds(2.5))
        let landscapeEarly = try await frame([Clip(mediaID: landscape.id, sourceRange: range(3.5, 3))])
        let portraitEarly = try await frame([Clip(mediaID: portrait.id, sourceRange: range(0.5, 3))])
        for point in points {
            let expected = landscapeEarly[point] * 0.75 + portraitEarly[point] * 0.25
            #expect(early.isClose(early[point], expected, within: 0.05), "\(point)")
        }
        // Past it, only the portrait.
        let past = try await render(built, at: seconds(4.5))
        let portraitLater = try await frame([Clip(mediaID: portrait.id, sourceRange: range(2.5, 3))])
        for point in points {
            #expect(past.isClose(past[point], portraitLater[point], within: 0.03), "\(point)")
        }
    }

    @Test func theTransformScalesAndMovesTheLayer() async throws {
        let full = try await frame([clip(landscape)])
        // Half size, in the top-left quarter.
        let moved = try await frame([clip(landscape) {
            $0.transform.scale = Animatable(0.5)
            $0.transform.position = Animatable(CGPoint(x: 0.25, y: 0.25))
        }])
        for point in [CGPoint(x: 1440, y: 810), CGPoint(x: 1000, y: 300), CGPoint(x: 300, y: 800)] {
            #expect(moved.brightness(at: point) < 0.02, "\(point)")
        }
        for point in points.map({ CGPoint(x: $0.x / 2, y: $0.y / 2) }) {
            let original = CGPoint(x: point.x * 2, y: point.y * 2)
            #expect(moved.isClose(moved[point], full[original], within: 0.08), "\(point)")
        }
    }

    @Test func theTransformTurnsTheLayerClockwise() async throws {
        let full = try await frame([clip(landscape)])
        // A quarter turn clockwise: the frame's top-left corner goes to the
        // top-right, fitted inside the frame at 1080 by 607.5.
        let turned = try await frame([clip(landscape) {
            $0.transform.rotation = Animatable(90)
            $0.transform.scale = Animatable(0.5625)
        }])
        #expect(turned.brightness(at: CGPoint(x: 400, y: 540)) < 0.02)
        // The original's (480, 270) lands at 960 + (540 - 270) × 0.5625 across
        // and 540 + (480 - 960) × 0.5625 down.
        let landed = CGPoint(x: 960 + 270 * 0.5625, y: 540 - 480 * 0.5625)
        #expect(turned.isClose(turned[landed], full[CGPoint(x: 480, y: 270)], within: 0.08))
    }

    @Test func aStillImageIsDrawnFittedIntoTheFrame() async throws {
        // A portrait photo, 1535 by 2729, fitted between x 656 and 1264 like
        // the portrait recording.
        let photo = MediaItem(name: "IMG_2459.JPG", kind: .image, location: .package(path: "IMG_2459.JPG"), metadata: MediaMetadata())
        let still = Clip(mediaID: photo.id, sourceRange: range(0, 3))
        let composed = try await frame([still], media: [photo])
        // The photo drawn into the same place in a frame of its own.
        let photoImage = try #require(
            CGImageSourceCreateWithURL(Samples.url("IMG_2459.JPG") as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        )
        let sRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil, width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: 0,
            space: sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .high
        let width = 1535 * 1080 / 2729.0
        context.draw(photoImage, in: CGRect(x: 960 - width / 2, y: 0, width: width, height: 1080))
        let fitted = FramePixels(try #require(context.makeImage()))
        for point in points {
            #expect(composed.isClose(composed[point], fitted[point], within: 0.05), "\(point)")
        }
        #expect(composed.brightness(at: CGPoint(x: 300, y: 540)) < 0.02)
        #expect(composed.brightness(at: CGPoint(x: 1600, y: 540)) < 0.02)
    }

    @Test func aRotatedRecordingShowsUpright() async throws {
        // The landscape recording, marked as filmed with the phone turned a
        // quarter clockwise, as phones mark portrait video.
        let url = try await rotatedCopy(of: Samples.url("IMG_3311.mp4"))
        defer { try? FileManager.default.removeItem(at: url) }
        let rotated = MediaItem(name: "Rotated.mov", kind: .video, location: .package(path: url.path), metadata: MediaMetadata())
        let composed = try await frame([clip(rotated)], media: [rotated])

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let upright = FramePixels(try await generator.image(at: seconds(3)).image)
        #expect(upright.width == 1080 && upright.height == 1920)
        // Pillarboxed between x 656 and 1264, scaled by 1080 / 1920.
        #expect(composed.brightness(at: CGPoint(x: 300, y: 540)) < 0.02)
        let scale = 1080.0 / 1920
        for point in [CGPoint(x: 300, y: 400), CGPoint(x: 540, y: 960), CGPoint(x: 800, y: 1500)] {
            let placed = CGPoint(x: 656 + point.x * scale, y: point.y * scale)
            #expect(composed.isClose(composed[placed], upright[point], within: 0.08), "\(point)")
        }
    }

    @Test func blendModesMixWithTheLayersUnder() async throws {
        let picture = try await frame([clip(landscape)])
        let multiplied = try await frame([clip(landscape), clip(landscape) { $0.blendMode = .multiply }])
        let screened = try await frame([clip(landscape), clip(landscape) { $0.blendMode = .screen }])
        let differenced = try await frame([clip(landscape), clip(landscape) { $0.blendMode = .difference }])
        for point in points {
            let colour = picture[point]
            #expect(multiplied.isClose(multiplied[point], colour * colour, within: 0.03), "\(point)")
            #expect(screened.isClose(screened[point], 1 - (1 - colour) * (1 - colour), within: 0.03), "\(point)")
            #expect(differenced.isClose(differenced[point], .zero, within: 0.02), "\(point)")
        }
    }

    @Test func parameterEditsShowWithoutARebuild() async throws {
        var project = Project(media: [landscape, portrait], tracks: [
            Track(kind: .video, clips: [clip(landscape)]), Track(kind: .video, clips: [clip(portrait)]),
        ])
        let snapshot = ProjectSnapshot(project)
        let built = try await CompositionBuilder(project: project, mediaResolver: resolver, snapshot: snapshot).build()
        let bottom = try await frame([clip(landscape)])
        let top = try await frame([clip(portrait)])
        let before = try await render(built, at: time)
        #expect(before.isClose(before[points[1]], top[points[1]], within: 0.03))

        let topClip = project.tracks[1].clips[0].id
        project.tracks[1].update(topClip) { $0.opacity = Animatable(0) }
        snapshot.update(project)
        let after = try await render(built, at: time)
        for point in points {
            #expect(after.isClose(after[point], bottom[point], within: 0.03), "\(point)")
        }
    }

    @Test func exportsDrawThroughTheCompositor() async throws {
        let project = Project(media: [landscape, portrait], tracks: [
            Track(kind: .video, clips: [clip(landscape)]),
            Track(kind: .video, clips: [clip(portrait) { $0.blendMode = .screen; $0.opacity = Animatable(0.7) }]),
        ])
        let built = try await CompositionBuilder(project: project, mediaResolver: resolver).build()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Exporter().export(RenderSource(built), settings: ExportSettings(resolution: .project, quality: .high), to: url)

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let exported = FramePixels(try await generator.image(at: time).image)
        let previewed = try await render(built, at: time)
        for point in points {
            #expect(exported.isClose(exported[point], previewed[point], within: 0.06), "\(point)")
        }
    }

    @Test func aCPUOnlyCompositionDrawsTheSame() async throws {
        let project = Project(media: [landscape, portrait], tracks: [
            Track(kind: .video, clips: [clip(landscape)]),
            Track(kind: .video, clips: [clip(portrait) { $0.opacity = Animatable(0.5) }]),
        ])
        var builder = CompositionBuilder(project: project, mediaResolver: resolver)
        let gpu = try await render(builder.build(), at: time)
        builder.usesGPU = false
        let cpu = try await render(builder.build(), at: time)
        for point in points {
            #expect(cpu.isClose(cpu[point], gpu[point], within: 0.02), "\(point)")
        }
    }

    // MARK: - Helpers

    private func render(_ built: BuiltComposition, at time: CMTime) async throws -> FramePixels {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = FramePixels(try await generator.image(at: time).image)
        #expect(image.width == 1920 && image.height == 1080)
        return image
    }

    /// A reference movie of a file whose video track says to turn its frames
    /// a quarter clockwise.
    private func rotatedCopy(of source: URL) async throws -> URL {
        let movie = AVMutableMovie(url: source)
        let track = try #require(try await movie.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        track.preferredTransform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        try movie.writeHeader(to: url, fileType: .mov, options: .addMovieHeaderToDestination)
        return url
    }
}

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
    CMTimeRange(start: seconds(start), duration: seconds(duration))
}

/// An image's pixels as colours from 0 to 1, read in the image's own colour
/// space so they're the values the compositor wrote.
private struct FramePixels {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }

    /// The average colour of a few pixels around a point, measured from the
    /// top left, so a pixel off doesn't matter.
    subscript(point: CGPoint) -> SIMD3<Double> {
        var sum = SIMD3<Double>.zero
        var count = 0.0
        for dy in -2...2 {
            for dx in -2...2 {
                let x = min(max(Int(point.x) + dx, 0), width - 1)
                let y = min(max(Int(point.y) + dy, 0), height - 1)
                let index = (y * width + x) * 4
                sum += SIMD3(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2])) / 255
                count += 1
            }
        }
        return sum / count
    }

    func brightness(at point: CGPoint) -> Double {
        let colour = self[point]
        return (colour.x + colour.y + colour.z) / 3
    }

    func isClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, within tolerance: Double) -> Bool {
        let difference = abs(a - b)
        return max(difference.x, difference.y, difference.z) <= tolerance
    }
}

// Described briefly, so a failed expectation doesn't print every pixel.
extension FramePixels: CustomStringConvertible {
    var description: String { "\(width)×\(height) pixels" }
}
