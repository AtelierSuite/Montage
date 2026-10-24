import CoreMedia
import Foundation

extension AVIWriter {
    /// The video stream of an AVI file. AVI plays at a constant frame rate:
    /// every frame appended lasts one frame duration.
    public struct VideoSettings: Sendable, Hashable {
        public enum Codec: Sendable, Hashable {
            /// Motion JPEG (`MJPG`): every frame is a complete JPEG image, so
            /// every frame is a keyframe.
            case motionJPEG
            /// H.264 (`H264`), stored as an Annex B byte stream with the
            /// parameter sets repeated before every keyframe.
            case h264

            /// The four-character code naming the codec in the stream header
            /// and the bitmap header.
            var fourCC: String {
                switch self {
                case .motionJPEG: "MJPG"
                case .h264: "H264"
                }
            }
        }

        public var codec: Codec
        /// The size of the frames in pixels, up to 32767 on each side.
        public var width: Int
        public var height: Int
        public var frameRate: FrameRate

        public init(codec: Codec, width: Int, height: Int, frameRate: FrameRate) {
            self.codec = codec
            self.width = width
            self.height = height
            self.frameRate = frameRate
        }

        var isValid: Bool {
            (1...Int(Int16.max)).contains(width) && (1...Int(Int16.max)).contains(height) && frameRate.isValid
        }
    }

    /// Frames per second as an exact fraction, such as 30000/1001 for 29.97.
    public struct FrameRate: Sendable, Hashable {
        public var numerator: UInt32
        public var denominator: UInt32

        public init(_ numerator: UInt32, _ denominator: UInt32 = 1) {
            self.numerator = numerator
            self.denominator = denominator
        }

        /// The frame rate whose frames last `frameDuration`, such as
        /// 1001/30000 seconds for 29.97 frames per second.
        public init?(frameDuration: CMTime) {
            guard frameDuration.isNumeric, frameDuration.value > 0, frameDuration.timescale > 0,
                  let numerator = UInt32(exactly: frameDuration.timescale),
                  let denominator = UInt32(exactly: frameDuration.value)
            else { return nil }
            self.init(numerator, denominator)
        }

        var isValid: Bool { numerator > 0 && denominator > 0 }
    }

    /// The audio stream of an AVI file: uncompressed PCM, 16-bit signed
    /// little-endian samples, with the channels interleaved.
    public struct AudioSettings: Sendable, Hashable {
        public var sampleRate: Int
        /// One (mono) or two (stereo).
        public var channels: Int

        public init(sampleRate: Int, channels: Int) {
            self.sampleRate = sampleRate
            self.channels = channels
        }

        static let bytesPerSample = 2

        /// The bytes in one sample of every channel.
        var blockAlign: Int { channels * Self.bytesPerSample }

        var bytesPerSecond: Int { sampleRate * blockAlign }

        var isValid: Bool {
            (1...2).contains(channels) && (1...384_000).contains(sampleRate)
        }
    }
}

/// Why an AVI file couldn't be written. Errors from the file system itself,
/// such as a full disk, are thrown as they are.
public enum AVIWriterError: LocalizedError, Equatable {
    /// The frame size, frame rate or audio format can't be written as AVI.
    case invalidSettings
    /// A frame or audio buffer isn't in the format the stream was set up with.
    case unsupportedMedia
    /// The file has grown past what its index can describe.
    case tooLarge
    /// The writer has finished, been cancelled or failed, and can't take more.
    case notWriting

    public var errorDescription: String? {
        switch self {
        case .invalidSettings:
            String(localized: "AVIWriter.Error.InvalidSettings", bundle: #bundle)
        case .unsupportedMedia:
            String(localized: "AVIWriter.Error.UnsupportedMedia", bundle: #bundle)
        case .tooLarge:
            String(localized: "AVIWriter.Error.TooLarge", bundle: #bundle)
        case .notWriting:
            String(localized: "AVIWriter.Error.NotWriting", bundle: #bundle)
        }
    }
}
