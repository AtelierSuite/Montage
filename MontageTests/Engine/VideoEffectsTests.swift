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

    // MARK: - Masks

    /// An effect that turns white black, to see plainly where it applies.
    private var darken: Effect.Kind {
        var correction = ColorCorrection()
        correction.exposure = Animatable(-20)
        return .colorCorrection(correction)
    }

    @Test func aRectangleMaskLimitsTheEffectToIt() {
        let image = Pixels.solid(display: 1)
        let output = apply(darken, to: image, mask: Mask(.rectangle))
        // The middle half of the 320 × 240 frame: 80 to 240 across, 60 to 180 down.
        #expect(Pixels.display(output, at: Pixels.middle).red < 0.01)
        #expect(Pixels.display(output, at: CGPoint(x: 85, y: 65)).red < 0.01)
        #expect(Pixels.display(output, at: CGPoint(x: 75, y: 160)).red > 0.99)
        #expect(Pixels.display(output, at: CGPoint(x: 160, y: 185)).red > 0.99)
    }

    @Test func anInvertedMaskLimitsTheEffectToOutsideIt() {
        let image = Pixels.solid(display: 1)
        let output = apply(darken, to: image, mask: Mask(.rectangle, isInverted: true))
        #expect(Pixels.display(output, at: Pixels.middle).red > 0.99)
        #expect(Pixels.display(output, at: CGPoint(x: 10, y: 10)).red < 0.01)
    }

    @Test func anEllipseMaskLeavesTheBoxsCorners() {
        let image = Pixels.solid(display: 1)
        let output = apply(darken, to: image, mask: Mask(.ellipse))
        #expect(Pixels.display(output, at: Pixels.middle).red < 0.01)
        // Inside the box, but outside the ellipse in it.
        #expect(Pixels.display(output, at: CGPoint(x: 90, y: 70)).red > 0.99)
        // Just inside the ellipse's ends, across and down.
        #expect(Pixels.display(output, at: CGPoint(x: 84, y: 120)).red < 0.05)
        #expect(Pixels.display(output, at: CGPoint(x: 160, y: 64)).red < 0.05)
    }

    @Test func aFeatheredMaskFadesAcrossItsEdge() {
        let image = Pixels.solid(display: 1)
        for shape in [Mask.Shape.rectangle, .ellipse] {
            let output = apply(darken, to: image, mask: Mask(shape, feather: 0.1))
            // On the edge, half way through the fade.
            let edge = Pixels.linear(output, at: CGPoint(x: 80, y: 120)).red
            #expect(edge > 0.3 && edge < 0.7, "\(shape)")
            #expect(Pixels.display(output, at: Pixels.middle).red < 0.01, "\(shape)")
            #expect(Pixels.display(output, at: CGPoint(x: 40, y: 120)).red > 0.99, "\(shape)")
        }
    }

    @Test func aPathMaskFollowsItsPoints() {
        let image = Pixels.solid(display: 1)
        let output = apply(darken, to: image, mask: Mask(.path, size: CGSize(width: 1, height: 1)))
        // The diamond touches the middle of each side of the frame.
        #expect(Pixels.display(output, at: Pixels.middle).red < 0.01)
        #expect(Pixels.display(output, at: CGPoint(x: 160, y: 10)).red < 0.01)
        #expect(Pixels.display(output, at: CGPoint(x: 20, y: 20)).red > 0.99)
        #expect(Pixels.display(output, at: CGPoint(x: 300, y: 220)).red > 0.99)
    }

    @Test func aMaskTurnsClockwise() {
        let image = Pixels.solid(display: 1)
        // A bar across, a tenth as tall as the frame, turned a little
        // clockwise: its right end goes down, its left end up.
        let mask = Mask(.rectangle, size: CGSize(width: 0.8, height: 0.1), rotation: 20)
        let output = apply(darken, to: image, mask: mask)
        #expect(Pixels.display(output, at: CGPoint(x: 260, y: 150)).red < 0.01)
        #expect(Pixels.display(output, at: CGPoint(x: 60, y: 90)).red < 0.01)
        #expect(Pixels.display(output, at: CGPoint(x: 260, y: 90)).red > 0.99)
    }

    @Test func aKeyframedMaskMovesWithTheClip() {
        let image = Pixels.solid(display: 1)
        var mask = Mask(.rectangle, size: CGSize(width: 0.2, height: 0.2))
        mask.center = Animatable(.zero, keyframes: [
            Keyframe(time: .zero, value: CGPoint(x: 0.2, y: 0.5)),
            Keyframe(time: CMTime(value: 2, timescale: 1), value: CGPoint(x: 0.8, y: 0.5)),
        ])
        let midway = apply(darken, to: image, at: CMTime(value: 1, timescale: 1), mask: mask)
        #expect(Pixels.display(midway, at: Pixels.middle).red < 0.01)
        #expect(Pixels.display(midway, at: CGPoint(x: 64, y: 120)).red > 0.99)
        let start = apply(darken, to: image, at: .zero, mask: mask)
        #expect(Pixels.display(start, at: CGPoint(x: 64, y: 120)).red < 0.01)
        #expect(Pixels.display(start, at: Pixels.middle).red > 0.99)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func aMaskedMosaicLeavesThePhotoOutsideIt() throws {
        let photo = try Pixels.photo()
        var mosaic = Mosaic(style: .pixelate)
        mosaic.scale = Animatable(0.1)
        let output = apply(.mosaic(mosaic), to: photo, mask: Mask(.ellipse, size: CGSize(width: 0.3, height: 0.3)))
        for point in [CGPoint(x: 10, y: 10), CGPoint(x: 300, y: 50), CGPoint(x: 30, y: 200)] {
            #expect(Pixels.display(output, at: point).isClose(to: Pixels.display(photo, at: point)))
        }
    }

    // MARK: - Turned off

    @Test func skipsEffectsThatAreOffOrForSound() {
        let image = Pixels.solid(display: 0.5)
        var correction = ColorCorrection()
        correction.exposure = Animatable(1)
        let context = VideoEffectContext(renderSize: Pixels.size, clipTime: .zero)
        #expect(Effect(isEnabled: false, .colorCorrection(correction)).apply(to: image, in: context) === image)
        #expect(Effect(.gain(Gain())).apply(to: image, in: context) === image)
        // In order: darkening then pixelating is still dark.
        let effects = [Effect(darken), Effect(.mosaic(Mosaic()))]
        #expect(Pixels.display(effects.apply(to: image, in: context), at: Pixels.middle).red < 0.01)
    }

    // MARK: - Helpers

    private func apply(_ kind: Effect.Kind, to image: CIImage, at time: CMTime = .zero, mask: Mask? = nil) -> CIImage {
        Effect(kind, mask: mask).apply(to: image, in: VideoEffectContext(renderSize: image.extent.size, clipTime: time))
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
