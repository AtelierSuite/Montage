import Foundation

/// An effect brought in from another editor that Montage has no match for,
/// such as a third-party plug-in or another app's own color grade. It's kept
/// on its clip, turned off, so nothing is silently lost: it names what it
/// was and carries the parameters it had, and is written back out as it was
/// read when the project goes back to the app it came from.
///
/// Nothing renders it; turned on, it still leaves the clip as it is.
public struct UnsupportedEffect: Equatable, Sendable, Codable {
    /// One of the effect's parameters, as the file had it.
    public struct Parameter: Equatable, Sendable, Codable {
        public var name: String
        /// The file's own identifier for the parameter, where it has one.
        public var key: String?
        /// The value as written, which may be a number, several numbers or
        /// text. Nil if the file gave the parameter no value.
        public var value: String?
        /// Whether the parameter changes over time in the original.
        public var isAnimated: Bool

        public init(name: String, key: String? = nil, value: String? = nil, isAnimated: Bool = false) {
            self.name = name
            self.key = key
            self.value = value
            self.isAnimated = isAnimated
        }
    }

    /// The format the effect was read from, such as "fcpxml" or "xmeml".
    public var format: String
    /// The effect's ID in that format, such as a Final Cut effect's UID.
    public var identifier: String
    /// The name the other app showed for the effect.
    public var name: String
    /// Whether it changed the picture rather than the sound.
    public var isVideo: Bool
    public var parameters: [Parameter]
    /// The effect exactly as the file wrote it, to write back unchanged to
    /// a file of the same format.
    public var original: String?

    public init(
        format: String, identifier: String, name: String, isVideo: Bool,
        parameters: [Parameter] = [], original: String? = nil
    ) {
        self.format = format
        self.identifier = identifier
        self.name = name
        self.isVideo = isVideo
        self.parameters = parameters
        self.original = original
    }
}
