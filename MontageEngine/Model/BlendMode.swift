/// How a clip's picture mixes with the layers under it.
///
/// The colours are blended as they're stored, gamma-encoded, the way most
/// editors blend by default; the clip's opacity then fades between the
/// layers under it and the blended result.
public enum BlendMode: String, Codable, Sendable, CaseIterable {
    /// Covers what's under it.
    case normal
    /// Darkens: white leaves what's under it, black makes black.
    case multiply
    /// Lightens: black leaves what's under it, white makes white.
    case screen
    /// Multiplies the dark parts of what's under it and screens the light.
    case overlay
    case softLight
    case hardLight
    /// The darker of the two, colour by colour.
    case darken
    /// The lighter of the two, colour by colour.
    case lighten
    case colorDodge
    case colorBurn
    case difference
    case exclusion
    /// Adds the colours, so light adds to light.
    case add
    case hue
    case saturation
    case color
    case luminosity
}
