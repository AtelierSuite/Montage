/// A video project: everything the user edits, and nothing derived from it.
/// Thumbnails, waveforms and proxies are caches beside it, made again from
/// the media whenever they're missing.
public struct Project: Codable, Equatable, Sendable {
    /// The version of the project format this build writes. Raise it, with a
    /// migration from the version before, whenever the model changes shape.
    public static let currentFormatVersion = 1

    /// The version of the project format the project was saved in.
    public var formatVersion: Int

    public init() {
        formatVersion = Self.currentFormatVersion
    }
}
