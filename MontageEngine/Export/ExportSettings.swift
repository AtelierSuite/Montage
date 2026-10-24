import CoreGraphics
import CoreMedia
import Foundation
import UniformTypeIdentifiers

/// The container an export is written in.
public enum ExportFormat: String, CaseIterable, Codable, Hashable, Sendable {
    /// H.264 or HEVC video with AAC audio, written by AVFoundation.
    case mp4
    /// Motion JPEG or H.264 video with PCM audio, in a RIFF/OpenDML container
    /// written by Montage itself, since AVFoundation can't.
    case avi

    public var fileExtension: String {
        switch self {
        case .mp4: "mp4"
        case .avi: "avi"
        }
    }

    public var contentType: UTType {
        switch self {
        case .mp4: .mpeg4Movie
        case .avi: .avi
        }
    }

    /// The video codecs the container can carry, the default first.
    public var videoCodecs: [ExportVideoCodec] {
        switch self {
        case .mp4: [.h264, .hevc]
        case .avi: [.motionJPEG, .h264]
        }
    }

    /// Photos takes MP4, but not AVI.
    public var canSaveToPhotos: Bool { self == .mp4 }
}

/// How the video is compressed.
public enum ExportVideoCodec: String, CaseIterable, Codable, Hashable, Sendable {
    case h264
    case hevc
    /// Every frame a JPEG: large, but plays almost anywhere that reads AVI.
    case motionJPEG

    public var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        case .motionJPEG: kCMVideoCodecType_JPEG
        }
    }

    /// How many bits each pixel of a frame takes at medium quality. Used to
    /// pick bit rates and to estimate the file's size.
    fileprivate var bitsPerPixel: Double {
        switch self {
        case .h264: 0.08
        case .hevc: 0.05
        case .motionJPEG: 1.0
        }
    }
}

/// The size of the exported frame.
public enum ExportResolution: Hashable, Codable, Sendable {
    /// The project's own size.
    case project
    /// Scaled so the frame's shorter side has this many pixels.
    case shortSide(Int)

    public static let hd720 = ExportResolution.shortSide(720)
    public static let hd1080 = ExportResolution.shortSide(1080)
    public static let uhd2160 = ExportResolution.shortSide(2160)

    /// The presets to offer for a project of this size: its own size, then
    /// the standard sizes smaller than it.
    public static func options(for renderSize: CGSize) -> [ExportResolution] {
        let shortSide = Int(min(renderSize.width, renderSize.height))
        return [.project] + [Self.uhd2160, .hd1080, .hd720].filter {
            guard case .shortSide(let side) = $0 else { return false }
            return side < shortSide
        }
    }

    /// The frame size for a project of this size, keeping its shape, with
    /// even sides as the encoders need.
    public func size(for renderSize: CGSize) -> CGSize {
        let width = max(renderSize.width, 2)
        let height = max(renderSize.height, 2)
        switch self {
        case .project:
            return CGSize(width: Self.even(width), height: Self.even(height))
        case .shortSide(let side):
            let scale = CGFloat(side) / min(width, height)
            return CGSize(width: Self.even(width * scale), height: Self.even(height * scale))
        }
    }

    private static func even(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }
}

/// The frame rate of the export.
public enum ExportFrameRate: Hashable, Codable, Sendable {
    /// The project's own frame rate.
    case project
    /// This many frames a second.
    case fps(Int)

    public static let standard: [ExportFrameRate] = [.project, .fps(24), .fps(25), .fps(30), .fps(50), .fps(60)]

    public func frameDuration(project: CMTime) -> CMTime {
        switch self {
        case .project: project.isNumeric && project > .zero ? project : CMTime(value: 1, timescale: 30)
        case .fps(let rate): CMTime(value: 1, timescale: CMTimeScale(max(rate, 1)))
        }
    }
}

/// How hard the video is compressed.
public enum ExportQuality: String, CaseIterable, Codable, Hashable, Sendable {
    case low, medium, high, maximum

    /// Scales the codec's bits per pixel.
    fileprivate var bitRateFactor: Double {
        switch self {
        case .low: 0.5
        case .medium: 1
        case .high: 1.6
        case .maximum: 2.6
        }
    }

    /// The JPEG quality for Motion JPEG, from 0 to 1.
    public var jpegQuality: Double {
        switch self {
        case .low: 0.5
        case .medium: 0.7
        case .high: 0.85
        case .maximum: 0.95
        }
    }
}

/// Everything the user chooses about an export.
public struct ExportSettings: Hashable, Codable, Sendable {
    public var format: ExportFormat {
        didSet { if !format.videoCodecs.contains(codec) { codec = format.videoCodecs[0] } }
    }
    public var codec: ExportVideoCodec
    public var resolution: ExportResolution
    public var frameRate: ExportFrameRate
    public var quality: ExportQuality

    public init(
        format: ExportFormat = .mp4, codec: ExportVideoCodec? = nil, resolution: ExportResolution = .project,
        frameRate: ExportFrameRate = .project, quality: ExportQuality = .high
    ) {
        self.format = format
        let codec = codec ?? format.videoCodecs[0]
        self.codec = format.videoCodecs.contains(codec) ? codec : format.videoCodecs[0]
        self.resolution = resolution
        self.frameRate = frameRate
        self.quality = quality
    }

    // MARK: - Derived

    /// The audio is always stereo at 48 kHz.
    public static let audioSampleRate: Double = 48_000
    public static let audioChannelCount = 2

    /// The AAC bit rate in an MP4.
    public static let aacBitRate = 192_000

    /// The bit rate of the audio in this format, in bits per second: AAC in
    /// an MP4, 16-bit PCM in an AVI.
    public var audioBitRate: Int {
        switch format {
        case .mp4: Self.aacBitRate
        case .avi: Int(Self.audioSampleRate) * Self.audioChannelCount * 16
        }
    }

    /// The average bit rate to ask of the video encoder, in bits per second.
    public func videoBitRate(renderSize: CGSize, frameDuration: CMTime) -> Int {
        let size = resolution.size(for: renderSize)
        let rate = 1 / self.frameRate.frameDuration(project: frameDuration).seconds
        let bitsPerSecond = size.width * size.height * rate * codec.bitsPerPixel * quality.bitRateFactor
        return max(Int(bitsPerSecond), 250_000)
    }

    /// Roughly how big the file will be, in bytes, for this long a video.
    public func estimatedFileSize(duration: CMTime, renderSize: CGSize, frameDuration: CMTime, hasAudio: Bool = true) -> Int64 {
        guard duration.isNumeric, duration > .zero else { return 0 }
        let seconds = duration.seconds
        var bits = Double(videoBitRate(renderSize: renderSize, frameDuration: frameDuration)) * seconds
        if hasAudio { bits += Double(audioBitRate) * seconds }
        // The container's own headers and indexes.
        let overhead = format == .avi ? 1.01 : 1.005
        return Int64(bits / 8 * overhead)
    }
}
