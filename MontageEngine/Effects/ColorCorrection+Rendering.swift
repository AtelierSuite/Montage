import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia

extension ColorCorrection {
    /// The picture corrected as the parameters are at `time`. Adjustments
    /// left neutral are skipped, so a correction that changes nothing costs
    /// nothing.
    func apply(to image: CIImage, at time: CMTime) -> CIImage {
        var image = image

        let exposure = exposure.value(at: time)
        if exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(exposure)
            image = filter.outputImage ?? image
        }

        let brightness = brightness.value(at: time)
        let contrast = contrast.value(at: time)
        let saturation = saturation.value(at: time)
        if brightness != 0 || contrast != 1 || saturation != 1 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.brightness = Float(brightness)
            filter.contrast = Float(contrast)
            filter.saturation = Float(saturation)
            image = filter.outputImage ?? image
        }

        let temperature = temperature.value(at: time)
        let tint = tint.value(at: time)
        if temperature != Self.neutralTemperature || tint != 0 {
            // The picture is taken as lit at the temperature given, and
            // turned to daylight: a higher temperature is bluer light, so
            // correcting it warms the picture.
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: temperature, y: tint)
            filter.targetNeutral = CIVector(x: Self.neutralTemperature, y: 0)
            image = filter.outputImage ?? image
        }

        let lift = lift.value(at: time)
        let gamma = gamma.value(at: time)
        let gain = gain.value(at: time)
        if lift != RGBValues(0) || gamma != RGBValues(1) || gain != RGBValues(1) {
            let filter = CIFilter.colorCurves()
            filter.inputImage = image
            filter.curvesData = Self.curves(lift: lift, gamma: gamma, gain: gain)
            filter.curvesDomain = CIVector(x: 0, y: 1)
            // Graded on the values as shown, as colourists expect, rather
            // than on linear light.
            filter.colorSpace = Self.displayColorSpace
            image = filter.outputImage ?? image
        }

        let intensity = lutIntensity.value(at: time)
        if let lut, intensity > 0 {
            let filter = CIFilter.colorCubeWithColorSpace()
            filter.inputImage = image
            filter.cubeDimension = Float(lut.dimension)
            filter.cubeData = lut.data
            // Tables are made for values as shown, like the grade above.
            filter.colorSpace = Self.displayColorSpace
            if let looked = filter.outputImage {
                image = intensity >= 1 ? looked : image.dissolved(to: looked, by: intensity)
            }
        }

        return image
    }

    /// The temperature that leaves the picture's colour as it is.
    static let neutralTemperature = 6500.0

    static let displayColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    /// How many points each channel's curve is drawn with. The curve is
    /// smooth, so a few dozen are as good as many.
    static let curvePoints = 64

    /// Each channel's curve for a lift, gamma and gain, as the RGB triples
    /// `CIColorCurves` takes: the value is lifted, then scaled, then bent.
    static func curves(lift: RGBValues, gamma: RGBValues, gain: RGBValues) -> Data {
        func level(_ x: Double, lift: Double, gamma: Double, gain: Double) -> Float {
            let value = gain * (x + lift * (1 - x))
            return Float(value > 0 ? pow(value, 1 / max(gamma, 0.01)) : value)
        }
        var values: [Float] = []
        values.reserveCapacity(curvePoints * 3)
        for point in 0..<curvePoints {
            let x = Double(point) / Double(curvePoints - 1)
            values.append(level(x, lift: lift.red, gamma: gamma.red, gain: gain.red))
            values.append(level(x, lift: lift.green, gamma: gamma.green, gain: gain.green))
            values.append(level(x, lift: lift.blue, gamma: gamma.blue, gain: gain.blue))
        }
        return values.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

extension CIImage {
    /// The image `amount` of the way to `other`: 0 is this image, 1 the
    /// other.
    func dissolved(to other: CIImage, by amount: Double) -> CIImage {
        let filter = CIFilter.dissolveTransition()
        filter.inputImage = self
        filter.targetImage = other
        filter.time = Float(min(max(amount, 0), 1))
        return filter.outputImage ?? other
    }
}
