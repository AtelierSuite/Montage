import CoreGraphics
import CoreMedia
import Foundation

/// A piece of media imported into the project. Clips on the timeline point
/// at one of these rather than at a file, so relinking or moving the file
/// only ever changes the item.
public struct MediaItem: Identifiable, Equatable, Sendable {
    public typealias ID = UUID

    public enum Kind: String, Codable, Sendable {
        case video, audio, image
    }

    public var id: ID
    /// The name the library shows, from the file it was imported from.
    public var name: String
    public var kind: Kind
    public var location: MediaLocation
    public var metadata: MediaMetadata
    /// The library's bin the item is filed in, or nil for none.
    public var binID: MediaBin.ID?

    public init(
        id: ID = UUID(), name: String, kind: Kind, location: MediaLocation, metadata: MediaMetadata,
        binID: MediaBin.ID? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.location = location
        self.metadata = metadata
        self.binID = binID
    }
}

extension MediaItem: Codable {}

extension MediaItem {
    /// What a clip of the item holds: a still for an image, else media.
    public var content: ClipContent {
        kind == .image ? .image(id) : .media(id)
    }
}

/// Where a media item's file is.
public enum MediaLocation: Equatable, Sendable {
    /// Copied into the project package, at a path relative to the package,
    /// such as `Media/Clip.mov`.
    case package(path: String)
    /// Left where it was, on the Mac, and found again through a
    /// security-scoped bookmark.
    case bookmark(Data)
}

extension MediaLocation: Codable {
    private enum CodingKeys: String, CodingKey {
        case package, bookmark
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let path = try container.decodeIfPresent(String.self, forKey: .package) {
            self = .package(path: path)
        } else {
            self = .bookmark(try container.decode(Data.self, forKey: .bookmark))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .package(let path): try container.encode(path, forKey: .package)
        case .bookmark(let data): try container.encode(data, forKey: .bookmark)
        }
    }
}

/// What the media is like, read once when it's imported so the editor can
/// lay it out without opening the file.
public struct MediaMetadata: Equatable, Sendable {
    /// How long the media runs. Zero for a still image, which lasts as long
    /// as its clip is made.
    public var duration: CMTime
    /// The size of the frames as stored, before `rotation`.
    public var naturalSize: CGSize
    /// Clockwise rotation, in degrees, to show the frames upright: 0, 90, 180
    /// or 270. Phones record portrait video as rotated landscape frames.
    public var rotation: Int
    /// The frame rate the video is meant to play at. Zero without video.
    public var nominalFrameRate: Double
    /// Whether frames come at uneven intervals, as phone video often does.
    public var isVariableFrameRate: Bool
    /// Audio channels in the main audio track. Zero without audio.
    public var audioChannelCount: Int
    public var audioSampleRate: Double

    public init(
        duration: CMTime = .zero, naturalSize: CGSize = .zero, rotation: Int = 0,
        nominalFrameRate: Double = 0, isVariableFrameRate: Bool = false,
        audioChannelCount: Int = 0, audioSampleRate: Double = 0
    ) {
        self.duration = duration
        self.naturalSize = naturalSize
        self.rotation = rotation
        self.nominalFrameRate = nominalFrameRate
        self.isVariableFrameRate = isVariableFrameRate
        self.audioChannelCount = audioChannelCount
        self.audioSampleRate = audioSampleRate
    }

    public var hasVideo: Bool { naturalSize != .zero }
    public var hasAudio: Bool { audioChannelCount > 0 }

    /// The size of the frames once turned upright.
    public var presentationSize: CGSize {
        rotation % 180 == 0 ? naturalSize : CGSize(width: naturalSize.height, height: naturalSize.width)
    }
}

extension MediaMetadata: Codable {
    private enum CodingKeys: String, CodingKey {
        case duration, naturalSize, rotation, nominalFrameRate, isVariableFrameRate, audioChannelCount, audioSampleRate
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        duration = try container.decode(CMTime.self, forKey: .duration)
        naturalSize = try container.decodeIfPresent(CGSize.self, forKey: .naturalSize) ?? .zero
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        nominalFrameRate = try container.decodeIfPresent(Double.self, forKey: .nominalFrameRate) ?? 0
        isVariableFrameRate = try container.decodeIfPresent(Bool.self, forKey: .isVariableFrameRate) ?? false
        audioChannelCount = try container.decodeIfPresent(Int.self, forKey: .audioChannelCount) ?? 0
        audioSampleRate = try container.decodeIfPresent(Double.self, forKey: .audioSampleRate) ?? 0
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(duration, forKey: .duration)
        try container.encode(naturalSize, forKey: .naturalSize)
        try container.encode(rotation, forKey: .rotation)
        try container.encode(nominalFrameRate, forKey: .nominalFrameRate)
        try container.encode(isVariableFrameRate, forKey: .isVariableFrameRate)
        try container.encode(audioChannelCount, forKey: .audioChannelCount)
        try container.encode(audioSampleRate, forKey: .audioSampleRate)
    }
}
