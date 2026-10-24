import AVFoundation
import CoreGraphics
import CoreMedia
import ImageIO
@testable import MontageEngine
import Testing
import UniformTypeIdentifiers

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
    CMTimeRange(start: seconds(start), duration: seconds(duration))
}

private let red = RGBAColor(red: 1, green: 0, blue: 0)
private let green = RGBAColor(red: 0, green: 1, blue: 0)
private let blue = RGBAColor(red: 0, green: 0, blue: 1)

/// Text, shapes and stills drawn into frames by the compositor, checked
/// pixel by pixel.
struct LayerRenderingTests {
    private let centre = CGPoint(x: 960, y: 540)

    private func shape(_ kind: ShapeContent.Kind = .rectangle, colour: RGBAColor = red, _ change: (inout ShapeContent) -> Void = { _ in }) -> ShapeContent {
        var shape = ShapeContent(kind, size: CGSize(width: 600, height: 400), fill: LayerFill(color: colour), stroke: LayerStroke())
        change(&shape)
        return shape
    }

    private func clip(_ content: ClipContent, _ change: (inout Clip) -> Void = { _ in }) -> Clip {
        var clip = Clip(content: content, sourceRange: range(0, 3))
        change(&clip)
        return clip
    }

    private func frame(_ clips: [Clip], media: [MediaItem] = [], resolver: MediaResolver = .none, at time: CMTime = seconds(1)) async throws -> LayerPixels {
        let project = Project(media: media, tracks: clips.map { Track(kind: .video, clips: [$0]) })
        let built = try await CompositionBuilder(project: project, mediaResolver: resolver).build()
        #expect(built.skippedClips.isEmpty, "\(built.skippedClips)")
        return try await render(built, at: time)
    }

    private func render(_ built: BuiltComposition, at time: CMTime) async throws -> LayerPixels {
        let generator = AVAssetImageGenerator(asset: built.composition)
        generator.videoComposition = built.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let image = LayerPixels(try await generator.image(at: time).image)
        #expect(image.width == 1920 && image.height == 1080)
        return image
    }

    // MARK: - Shapes

    @Test func aShapeIsDrawnAtItsSizeInTheMiddle() async throws {
        let pixels = try await frame([clip(.shape(shape()))])
        #expect(pixels.isClose(pixels[centre], [1, 0, 0]))
        #expect(pixels.isClose(pixels[CGPoint(x: 960 - 280, y: 540 - 180)], [1, 0, 0]))
        #expect(pixels.isClose(pixels[CGPoint(x: 960 - 320, y: 540)], [0, 0, 0]))
        #expect(pixels.isClose(pixels[CGPoint(x: 960, y: 540 + 220)], [0, 0, 0]))
    }

    @Test func aShapeIsTransformedFadedAndBlendedLikeVideo() async throws {
        let white = clip(.shape(shape(colour: .white) { $0.size = Animatable(CGSize(width: 1920, height: 1080)) }))
        // Moved to the top-left quarter and halved.
        let moved = try await frame([clip(.shape(shape())) {
            $0.transform.position = Animatable(CGPoint(x: 0.25, y: 0.25))
            $0.transform.scale = Animatable(0.5)
        }])
        #expect(moved.isClose(moved[CGPoint(x: 480, y: 270)], [1, 0, 0]))
        #expect(moved.isClose(moved[CGPoint(x: 480 + 170, y: 270)], [0, 0, 0]))
        #expect(moved.isClose(moved[centre], [0, 0, 0]))

        let faded = try await frame([white, clip(.shape(shape())) { $0.opacity = Animatable(0.5) }])
        #expect(faded.isClose(faded[centre], [1, 0.5, 0.5], within: 0.03))

        let multiplied = try await frame([
            clip(.shape(shape(colour: RGBAColor(red: 1, green: 1, blue: 0)) { $0.size = Animatable(CGSize(width: 1920, height: 1080)) })),
            clip(.shape(shape(colour: RGBAColor(red: 0, green: 1, blue: 1)))) { $0.blendMode = .multiply },
        ])
        #expect(multiplied.isClose(multiplied[centre], [0, 1, 0]))
    }

    @Test func effectsAndMasksApplyToShapes() async throws {
        var darker = ColorCorrection()
        darker.exposure = Animatable(-2)
        // The mask's left half, so only the left of the shape darkens.
        var mask = Mask(.rectangle)
        mask.size = Animatable(CGSize(width: 0.5, height: 1))
        mask.center = Animatable(CGPoint(x: 0.25, y: 0.5))
        let pixels = try await frame([clip(.shape(shape(colour: .white))) {
            $0.effects = [Effect(.colorCorrection(darker), mask: mask)]
        }])
        #expect(pixels.brightness(at: CGPoint(x: 960 - 200, y: 540)) < 0.5)
        #expect(pixels.isClose(pixels[CGPoint(x: 960 + 200, y: 540)], [1, 1, 1]))
    }

    @Test func gradientsAndStrokesPaintTheShape() async throws {
        let pixels = try await frame([clip(.shape(shape(.ellipse) {
            $0.fill = LayerFill(style: .linearGradient, color: red, endColor: blue, angle: 0)
            $0.stroke = LayerStroke(isEnabled: true, color: green, width: 20)
        }))])
        let left = pixels[CGPoint(x: 960 - 200, y: 540)]
        let right = pixels[CGPoint(x: 960 + 200, y: 540)]
        #expect(left.x > left.z && right.z > right.x)
        // The stroke runs along the edge, centred on it.
        #expect(pixels.isClose(pixels[CGPoint(x: 960 - 300, y: 540)], [0, 1, 0], within: 0.1))
    }

    @Test func keyframedSizesAnimate() async throws {
        let growing = clip(.shape(shape { $0.size = Animatable(CGSize(width: 100, height: 100), keyframes: [
            Keyframe(time: .zero, value: CGSize(width: 100, height: 100)),
            Keyframe(time: seconds(2), value: CGSize(width: 900, height: 100)),
        ]) }))
        let early = try await frame([growing], at: seconds(0.25))
        let late = try await frame([growing], at: seconds(1.75))
        let point = CGPoint(x: 960 + 300, y: 540)
        #expect(early.isClose(early[point], [0, 0, 0]))
        #expect(late.isClose(late[point], [1, 0, 0]))
    }

    // MARK: - Text

    @Test func textIsDrawnOverItsBox() async throws {
        var text = TextContent("I")
        text.style = TextStyle(fontSize: 300, weight: .black, fill: LayerFill(color: .white))
        text.style.background = TextBackground(isEnabled: true, color: green, padding: 300, cornerRadius: 0)
        let pixels = try await frame([clip(.text(text))])
        // The letter in the middle, its box all round it.
        #expect(pixels.isClose(pixels[centre], [1, 1, 1], within: 0.05))
        #expect(pixels.isClose(pixels[CGPoint(x: 960 + 250, y: 540)], [0, 1, 0]))
        #expect(pixels.isClose(pixels[CGPoint(x: 960, y: 540 - 300)], [0, 1, 0]))
        #expect(pixels.isClose(pixels[CGPoint(x: 100, y: 100)], [0, 0, 0]))
    }

    @Test func outlinesShadowsAndGradientsChangeTheText() throws {
        let plain = TextContent("Montage")
        func drawn(_ change: (inout TextStyle) -> Void) throws -> (DrawnLayer, LayerPixels) {
            var text = plain
            change(&text.style)
            let drawn = try #require(TextRenderer.image(of: text.resolved(at: .zero, renderSize: CGSize(width: 1920, height: 1080)), scale: 1))
            return (drawn, LayerPixels(drawn.image))
        }
        let (_, base) = try drawn { _ in }
        let (_, outlined) = try drawn { $0.outline = LayerStroke(isEnabled: true, color: red, width: 8) }
        #expect(outlined.coverage > base.coverage)
        let (shadowed, _) = try drawn { $0.shadow = LayerShadow(isEnabled: true, blur: 20, offset: CGSize(width: 10, height: 10)) }
        #expect(shadowed.image.width > LayerPixels(try drawn { _ in }.0.image).width)

        let (_, gradient) = try drawn { $0.fill = LayerFill(style: .linearGradient, color: red, endColor: blue, angle: 0) }
        let (left, right) = gradient.inkAtTheEnds
        #expect(left.x > left.z && right.z > right.x)

        // Wider letter spacing and a bigger size make a wider picture.
        let (spaced, _) = try drawn { $0.letterSpacing = Animatable(40) }
        let (bigger, _) = try drawn { $0.fontSize = Animatable(200) }
        let (normal, _) = try drawn { _ in }
        #expect(spaced.image.width > normal.image.width)
        #expect(bigger.image.height > normal.image.height)
    }

    @Test func mixedFormattingDrawsEachRunInItsOwnColour() throws {
        let text = TextContent(runs: [TextRun("RRRR", formatting: .init(color: red)), TextRun("BBBB", formatting: .init(weight: .black, color: blue))])
        let drawn = try #require(TextRenderer.image(of: text.resolved(at: .zero, renderSize: CGSize(width: 1920, height: 1080)), scale: 1))
        let (left, right) = LayerPixels(drawn.image).inkAtTheEnds
        #expect(left.x > 0.8 && left.z < 0.2)
        #expect(right.z > 0.8 && right.x < 0.2)
    }

    @Test func picturesAreDrawnAgainOnlyWhenTheyChange() {
        let artwork = LayerArtwork(byteLimit: 64 * 1024 * 1024)
        var text = TextContent("Cached")
        let size = CGSize(width: 1920, height: 1080)
        _ = artwork.picture(of: .text(text), at: .zero, renderSize: size, scale: 1)
        _ = artwork.picture(of: .text(text), at: seconds(2), renderSize: size, scale: 1)
        #expect(artwork.drawCount == 1)
        // Keyframed, it's drawn for each value it takes, and kept for each.
        text.style.fontSize = Animatable(50, keyframes: [Keyframe(time: .zero, value: 50), Keyframe(time: seconds(1), value: 100)])
        _ = artwork.picture(of: .text(text), at: .zero, renderSize: size, scale: 1)
        _ = artwork.picture(of: .text(text), at: seconds(0.5), renderSize: size, scale: 1)
        _ = artwork.picture(of: .text(text), at: seconds(0.5), renderSize: size, scale: 1)
        // Past the last keyframe, it holds.
        _ = artwork.picture(of: .text(text), at: seconds(1), renderSize: size, scale: 1)
        _ = artwork.picture(of: .text(text), at: seconds(2), renderSize: size, scale: 1)
        #expect(artwork.drawCount == 4)
        // A sharper copy for a zoomed-in layer is a picture of its own.
        _ = artwork.picture(of: .text(text), at: seconds(2), renderSize: size, scale: 2)
        #expect(artwork.drawCount == 5)
    }

    @Test func theCacheKeepsToItsMemoryLimit() {
        // Room for about one picture of the text.
        let artwork = LayerArtwork(byteLimit: 200_000)
        let size = CGSize(width: 1920, height: 1080)
        let first = TextContent("First"), second = TextContent("Second")
        _ = artwork.picture(of: .text(first), at: .zero, renderSize: size, scale: 1)
        _ = artwork.picture(of: .text(second), at: .zero, renderSize: size, scale: 1)
        _ = artwork.picture(of: .text(second), at: .zero, renderSize: size, scale: 1)
        #expect(artwork.drawCount == 2)
        // The first was let go to make room.
        _ = artwork.picture(of: .text(first), at: .zero, renderSize: size, scale: 1)
        #expect(artwork.drawCount == 3)
    }

    @Test func zoomedLayersAreDrawnSharperInSteps() {
        #expect(LayerArtwork.drawingScale(outputScale: 1, layerScale: 1) == 1)
        #expect(LayerArtwork.drawingScale(outputScale: 1, layerScale: 0.3) == 1)
        #expect(LayerArtwork.drawingScale(outputScale: 0.5, layerScale: 1) == 0.5)
        #expect(LayerArtwork.drawingScale(outputScale: 1, layerScale: 1.1) == LayerArtwork.drawingScale(outputScale: 1, layerScale: 1.3))
        #expect(LayerArtwork.drawingScale(outputScale: 1, layerScale: 3) >= 3)
    }

    // MARK: - Stills

    /// A PNG, 200 by 100, blue on the left and clear on the right.
    private func halfClearPNG() throws -> URL {
        let context = try #require(CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    @Test func stillsShowTheirTransparencyAndFitTheFrame() async throws {
        let url = try halfClearPNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let image = MediaItem(name: "Half.png", kind: .image, location: .package(path: url.path), metadata: MediaMetadata())
        let resolver = MediaResolver { item in
            guard case .package(let path) = item.location else { return nil }
            return URL(fileURLWithPath: path)
        }
        let backdrop = clip(.shape(shape { $0.size = Animatable(CGSize(width: 1920, height: 1080)) }))
        func still(_ fit: FrameFit) -> Clip {
            clip(.image(image.id)) { $0.fit = fit }
        }
        let fitted = try await frame([backdrop, still(.fit)], media: [image], resolver: resolver)
        // Fitted: 1920 by 960, between y 60 and 1020.
        #expect(fitted.isClose(fitted[CGPoint(x: 400, y: 540)], [0, 0, 1]))
        #expect(fitted.isClose(fitted[CGPoint(x: 1500, y: 540)], [1, 0, 0]))
        #expect(fitted.isClose(fitted[CGPoint(x: 400, y: 30)], [1, 0, 0]))
        let filled = try await frame([backdrop, still(.fill)], media: [image], resolver: resolver)
        #expect(filled.isClose(filled[CGPoint(x: 400, y: 30)], [0, 0, 1]))
        let stretched = try await frame([backdrop, still(.stretch)], media: [image], resolver: resolver)
        #expect(stretched.isClose(stretched[CGPoint(x: 400, y: 5)], [0, 0, 1]))
        #expect(stretched.isClose(stretched[CGPoint(x: 1000, y: 540)], [1, 0, 0]))
    }

    @Test(.enabled(if: Samples.isAvailable, "Needs the sample media"))
    func photosAreDrawnUpright() async throws {
        let photo = MediaItem(name: "IMG_2459.JPG", kind: .image, location: .package(path: "IMG_2459.JPG"), metadata: MediaMetadata())
        let resolver = MediaResolver { _ in Samples.url("IMG_2459.JPG") }
        let pixels = try await frame([clip(.image(photo.id))], media: [photo], resolver: resolver)
        #expect(pixels.brightness(at: centre) > 0.02)
    }

    // MARK: - Exporting

    @Test func aTimelineOfOnlyShapesExports() async throws {
        let project = Project(tracks: [Track(kind: .video, clips: [clip(.shape(shape()))])])
        let built = try await CompositionBuilder(project: project, mediaResolver: .none).build()
        #expect(built.duration == seconds(3))
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Exporter().export(RenderSource(built), settings: ExportSettings(resolution: .project, quality: .high), to: url)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        #expect(abs(duration.seconds - 3) < 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let exported = LayerPixels(try await generator.image(at: seconds(2.5)).image)
        #expect(exported.isClose(exported[centre], [1, 0, 0], within: 0.08))
        #expect(exported.isClose(exported[CGPoint(x: 200, y: 200)], [0, 0, 0], within: 0.08))
    }
}

/// An image's pixels as colours from 0 to 1, unpremultiplied where there's
/// transparency.
private struct LayerPixels: CustomStringConvertible {
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

    var description: String { "\(width)×\(height) pixels" }

    private func pixel(_ x: Int, _ y: Int) -> SIMD4<Double> {
        let index = (y * width + x) * 4
        return SIMD4(Double(bytes[index]), Double(bytes[index + 1]), Double(bytes[index + 2]), Double(bytes[index + 3])) / 255
    }

    /// The average colour of a few pixels around a point from the top left.
    subscript(point: CGPoint) -> SIMD3<Double> {
        var sum = SIMD3<Double>.zero
        for dy in -2...2 {
            for dx in -2...2 {
                let p = pixel(min(max(Int(point.x) + dx, 0), width - 1), min(max(Int(point.y) + dy, 0), height - 1))
                sum += SIMD3(p.x, p.y, p.z)
            }
        }
        return sum / 25
    }

    func brightness(at point: CGPoint) -> Double {
        let colour = self[point]
        return (colour.x + colour.y + colour.z) / 3
    }

    func isClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, within tolerance: Double = 0.03) -> Bool {
        let difference = abs(a - b)
        return max(difference.x, difference.y, difference.z) <= tolerance
    }

    /// How much of the picture is painted.
    var coverage: Double {
        var total = 0.0
        for y in 0..<height { for x in 0..<width { total += pixel(x, y).w } }
        return total
    }

    /// The average colour of the painted pixels in the left and right fifths.
    var inkAtTheEnds: (left: SIMD3<Double>, right: SIMD3<Double>) {
        func ink(_ columns: Range<Int>) -> SIMD3<Double> {
            var sum = SIMD3<Double>.zero
            var weight = 0.0
            for y in 0..<height {
                for x in columns {
                    let p = pixel(x, y)
                    guard p.w > 0.9 else { continue }
                    sum += SIMD3(p.x, p.y, p.z) / p.w
                    weight += 1
                }
            }
            return weight > 0 ? sum / weight : .zero
        }
        return (ink(0..<(width / 5)), ink((width * 4 / 5)..<width))
    }
}
