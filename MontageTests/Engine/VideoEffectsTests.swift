import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// Effects tried directly on images, a pixel at a time: plain colours and
/// gradients whose every value is known, and a frame from a real photo.
struct VideoEffectsTests {
    // MARK: - Colour correction

    @Test func exposureDoublesTheLightAStopUp() {
        let image = Pixels.solid(linear: 0.2)
        var correction = ColorCorrection()
        correction.exposure = Animatable(1)
        let pixel = Pixels.linear(apply(.colorCorrection(correction), to: image), at: Pixels.middle)
        #expect(abs(pixel.red - 0.4) < 0.01)
        #expect(abs(pixel.blue - 0.4) < 0.01)
    }

    @Test func aNeutralCorrectionLeavesTheImageAlone() {
        let image = Pixels.solid(linear: 0.3)
        let output = apply(.colorCorrection(ColorCorrection()), to: image)
        #expect(output === image)
    }

    @Test func aHigherTemperatureWarms() {
        let image = Pixels.solid(linear: 0.3)
        var correction = ColorCorrection()
        correction.temperature = Animatable(9000)
        let warmer = Pixels.linear(apply(.colorCorrection(correction), to: image), at: Pixels.middle)
        #expect(warmer.red > warmer.blue + 0.02)
        correction.temperature = Animatable(4000)
        let cooler = Pixels.linear(apply(.colorCorrection(correction), to: image), at: Pixels.middle)
        #expect(cooler.blue > cooler.red + 0.02)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func noSaturationLeavesGrey() throws {
        let photo = try Pixels.photo()
        var correction = ColorCorrection()
        correction.saturation = Animatable(0)
        let output = apply(.colorCorrection(correction), to: photo)
        for point in [CGPoint(x: 40, y: 40), CGPoint(x: 160, y: 120), CGPoint(x: 250, y: 200)] {
            let pixel = Pixels.display(output, at: point)
            #expect(abs(pixel.red - pixel.green) < 0.01 && abs(pixel.green - pixel.blue) < 0.01)
        }
    }

    @Test func liftGammaAndGainWorkOnTheValuesAsShown() {
        let image = Pixels.solid(display: 0.25)
        var correction = ColorCorrection()
        correction.gain = Animatable(RGBValues(red: 2, green: 1, blue: 1))
        correction.lift = Animatable(RGBValues(red: 0, green: 0, blue: 1.0 / 3))
        correction.gamma = Animatable(RGBValues(red: 1, green: 0.5, blue: 1))
        let pixel = Pixels.display(apply(.colorCorrection(correction), to: image), at: Pixels.middle)
        // Red doubled, green squared, blue lifted a third of the way to white.
        #expect(abs(pixel.red - 0.5) < 0.02)
        #expect(abs(pixel.green - 0.0625) < 0.02)
        #expect(abs(pixel.blue - 0.5) < 0.02)
    }

    @Test func aLookUpTableMapsEachColour() {
        let image = Pixels.solid(display: 0.25)
        var correction = ColorCorrection()
        correction.lut = .identity(dimension: 17) { 1 - $0 }
        let inverted = Pixels.display(apply(.colorCorrection(correction), to: image), at: Pixels.middle)
        #expect(abs(inverted.red - 0.75) < 0.02)
        // Half of it shows half way.
        correction.lutIntensity = Animatable(0.5)
        let half = Pixels.linear(apply(.colorCorrection(correction), to: image), at: Pixels.middle)
        let expected = (Pixels.toLinear(0.25) + Pixels.toLinear(0.75)) / 2
        #expect(abs(half.red - expected) < 0.02)
    }

    @Test func keyframedValuesAreTakenAtTheClipsTime() {
        let image = Pixels.solid(linear: 0.2)
        var correction = ColorCorrection()
        correction.exposure = Animatable(0, keyframes: [
            Keyframe(time: .zero, value: 0),
            Keyframe(time: CMTime(value: 2, timescale: 1), value: 2),
        ])
        let midway = Pixels.linear(apply(.colorCorrection(correction), to: image, at: CMTime(value: 1, timescale: 1)), at: Pixels.middle)
        #expect(abs(midway.red - 0.4) < 0.01)
        let end = Pixels.linear(apply(.colorCorrection(correction), to: image, at: CMTime(value: 3, timescale: 1)), at: Pixels.middle)
        #expect(abs(end.red - 0.8) < 0.01)
    }

    // MARK: - Mosaic

    @Test func pixelatesInSquaresFromTheCorner() {
        // A gradient across the frame: every column a different colour.
        let image = Pixels.horizontalGradient
        var mosaic = Mosaic(style: .pixelate)
        mosaic.scale = Animatable(16 / Pixels.size.width)
        let output = apply(.mosaic(mosaic), to: image)
        #expect(output.extent == image.extent)
        for block in [0, 16, 48, 160] {
            let first = Pixels.display(output, at: CGPoint(x: block, y: 10)).red
            let last = Pixels.display(output, at: CGPoint(x: block + 15, y: 30)).red
            let next = Pixels.display(output, at: CGPoint(x: block + 16, y: 10)).red
            #expect(abs(first - last) < 0.002, "block at \(block)")
            #expect(next > first + 0.01, "block after \(block)")
        }
    }

    @Test(.enabled(if: Samples.isAvailable))
    func pixelatesAPhotoInSquares() throws {
        let photo = try Pixels.photo()
        var mosaic = Mosaic(style: .pixelate)
        mosaic.scale = Animatable(20 / photo.extent.width)
        let output = apply(.mosaic(mosaic), to: photo)
        let corner = Pixels.display(output, at: CGPoint(x: 100, y: 100))
        for point in [CGPoint(x: 119, y: 100), CGPoint(x: 100, y: 119), CGPoint(x: 110, y: 110)] {
            #expect(Pixels.display(output, at: point).isClose(to: corner))
        }
    }

    @Test func blursWithoutFadingAtTheEdges() {
        let image = Pixels.solid(display: 0.6)
        var mosaic = Mosaic(style: .blur)
        mosaic.scale = Animatable(0.05)
        let output = apply(.mosaic(mosaic), to: image)
        #expect(output.extent == image.extent)
        let corner = Pixels.display(output, at: CGPoint(x: 0, y: 0))
        #expect(abs(corner.alpha - 1) < 0.001)
        #expect(abs(corner.red - 0.6) < 0.01)
    }

    @Test func coversWithACheckerboard() {
        let image = Pixels.solid(display: 0.5)
        var mosaic = Mosaic(style: .checkerboard)
        mosaic.scale = Animatable(20 / Pixels.size.width)
        let output = apply(.mosaic(mosaic), to: image)
        let first = Pixels.display(output, at: CGPoint(x: 5, y: 5)).red
        let beside = Pixels.display(output, at: CGPoint(x: 25, y: 5)).red
        let diagonal = Pixels.display(output, at: CGPoint(x: 25, y: 25)).red
        #expect(Set([first, beside].map { $0.rounded() }) == [0, 1])
        #expect(abs(first - diagonal) < 0.01)
    }

    @Test func strengthShowsPartOfTheMosaic() {
        let image = Pixels.solid(linear: 0.5)
        var mosaic = Mosaic(style: .checkerboard)
        mosaic.firstColor = Animatable(.black)
        mosaic.secondColor = Animatable(.black)
        mosaic.strength = Animatable(0, keyframes: [
            Keyframe(time: .zero, value: 0), Keyframe(time: CMTime(value: 1, timescale: 1), value: 1),
        ])
        let half = apply(.mosaic(mosaic), to: image, at: CMTime(value: 1, timescale: 2))
        #expect(abs(Pixels.linear(half, at: Pixels.middle).red - 0.25) < 0.01)
        #expect(apply(.mosaic(mosaic), to: image, at: .zero) === image)
    }

    // MARK: - Helpers

    private func apply(_ kind: Effect.Kind, to image: CIImage, at time: CMTime = .zero) -> CIImage {
        Effect(kind).apply(to: image, in: VideoEffectContext(renderSize: image.extent.size, clipTime: time))
    }
}

/// Test images, and reading their pixels back.
enum Pixels {
    static let size = CGSize(width: 320, height: 240)
    static let middle = CGPoint(x: 160, y: 120)
    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let displaySpace = CGColorSpace(name: CGColorSpace.sRGB)!
    /// One context for every test, as the compositor keeps one.
    static let context = CIContext(options: [.cacheIntermediates: false])

    struct Pixel: Equatable {
        var red, green, blue, alpha: Double

        func isClose(to other: Pixel) -> Bool {
            abs(red - other.red) < 0.002 && abs(green - other.green) < 0.002
                && abs(blue - other.blue) < 0.002 && abs(alpha - other.alpha) < 0.002
        }
    }

    /// A frame of one grey, given in linear light.
    static func solid(linear value: Double) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: linearSpace)!)
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// A frame of one grey, given as shown.
    static func solid(display value: Double) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, alpha: 1, colorSpace: displaySpace)!)
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// Black at the left edge to white at the right.
    static var horizontalGradient: CIImage {
        let filter = CIFilter.linearGradient()
        filter.point0 = .zero
        filter.point1 = CGPoint(x: size.width, y: 0)
        filter.color0 = CIColor(red: 0, green: 0, blue: 0, alpha: 1, colorSpace: displaySpace)!
        filter.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1, colorSpace: displaySpace)!
        return filter.outputImage!.cropped(to: CGRect(origin: .zero, size: size))
    }

    /// A photo from the samples, made as small as the test frames.
    static func photo() throws -> CIImage {
        let image = try #require(CIImage(contentsOf: Samples.url("IMG_2459.JPG"), options: [.applyOrientationProperty: true]))
        let scale = size.width / image.extent.width
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let moved = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        // Rendered once, so its pixels are fixed rather than resampled each time.
        let cgImage = try #require(context.createCGImage(moved, from: moved.extent.integral))
        return CIImage(cgImage: cgImage)
    }

    /// The pixel at a point measured from the top-left corner, in linear light.
    static func linear(_ image: CIImage, at point: CGPoint) -> Pixel {
        read(image, at: point, in: linearSpace)
    }

    /// The pixel at a point measured from the top-left corner, as shown.
    static func display(_ image: CIImage, at point: CGPoint) -> Pixel {
        read(image, at: point, in: displaySpace)
    }

    static func toLinear(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    /// Renders the whole image, as the compositor renders a whole frame,
    /// since some filters work out a region differently on its own, and
    /// reads one pixel of it.
    private static func read(_ image: CIImage, at point: CGPoint, in space: CGColorSpace) -> Pixel {
        let bounds = image.extent.isInfinite ? CGRect(origin: .zero, size: size) : image.extent.integral
        let width = Int(bounds.width)
        var values = [Float](repeating: 0, count: width * Int(bounds.height) * 4)
        context.render(image, toBitmap: &values, rowBytes: width * 16, bounds: bounds, format: .RGBAf, colorSpace: space)
        // The bitmap's first row is the image's top.
        let index = (Int(point.y) * width + Int(point.x)) * 4
        return Pixel(red: Double(values[index]), green: Double(values[index + 1]),
                     blue: Double(values[index + 2]), alpha: Double(values[index + 3]))
    }
}
