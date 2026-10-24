import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// Finds the face of a font family nearest a weight and slant, falling back
/// on the system font for a family that isn't installed, and slanting an
/// upright face for a family with no italic.
public enum FontResolver {
    private struct Key: Hashable {
        var family: String
        var weight: FontWeight
        var isItalic: Bool
    }

    private struct Face: @unchecked Sendable {
        var descriptor: CTFontDescriptor
        /// Whether the face is slanted itself; if one was asked for and it
        /// isn't, it's slanted when it's drawn.
        var isItalic: Bool
    }

    private static let faces = Mutex<[Key: Face]>([:])

    /// The font families installed, by name, in order.
    public static var families: [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        // Hidden system families start with a dot.
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public static func font(family: String, size: Double, weight: FontWeight, isItalic: Bool) -> CTFont {
        let key = Key(family: family, weight: weight, isItalic: isItalic)
        let face = faces.withLock { $0[key] } ?? {
            let face = findFace(for: key)
            faces.withLock { $0[key] = face }
            return face
        }()
        if isItalic && !face.isItalic {
            var slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            return CTFontCreateWithFontDescriptor(face.descriptor, size, &slant)
        }
        return CTFontCreateWithFontDescriptor(face.descriptor, size, nil)
    }

    private static func findFace(for key: Key) -> Face {
        let family = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: key.family] as CFDictionary)
        let mandatory = Set([kCTFontFamilyNameAttribute as String]) as CFSet
        let candidates = CTFontDescriptorCreateMatchingFontDescriptors(family, mandatory) as? [CTFontDescriptor] ?? []
        let scored = candidates.map { descriptor -> (Face, Double) in
            let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let isItalic = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
            // A face of the wrong slant is a worse match than any weight.
            let score = abs(weight - key.weight.trait) + (isItalic == key.isItalic ? 0 : 2)
            return (Face(descriptor: descriptor, isItalic: isItalic), score)
        }
        if let best = scored.min(by: { $0.1 < $1.1 }) { return best.0 }

        // The system font, at the weight asked for.
        let system = CTFontCopyFontDescriptor(CTFontCreateUIFontForLanguage(.system, 0, nil)!)
        var traits: [CFString: Any] = [kCTFontWeightTrait: key.weight.trait]
        if key.isItalic { traits[kCTFontSymbolicTrait] = CTFontSymbolicTraits.traitItalic.rawValue }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(system, [kCTFontTraitsAttribute: traits] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        let isItalic = CTFontGetSymbolicTraits(font).contains(.traitItalic)
        return Face(descriptor: descriptor, isItalic: isItalic)
    }
}
