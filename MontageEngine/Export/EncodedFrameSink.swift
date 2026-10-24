import CoreMedia
import Foundation

/// The streams an export hands a container writer, described before the
/// first frame arrives.
public struct EncodedStreamDescription: Sendable, Equatable {
    public struct Video: Sendable, Equatable {
        /// Motion JPEG or H.264.
        public var codec: ExportVideoCodec
        public var width: Int
        public var height: Int
        /// How long each frame lasts. Every frame lasts exactly this long, one
        /// after another, as AVI expects.
        public var frameDuration: CMTime
        /// The average bit rate asked of the encoder; for Motion JPEG, only a
        /// guess.
        public var averageBitRate: Int
    }

    public struct Audio: Sendable, Equatable {
        public var sampleRate: Int
        public var channelCount: Int
        /// Always 16: signed, little-endian, interleaved.
        public var bitsPerSample: Int

        public var bytesPerFrame: Int { channelCount * bitsPerSample / 8 }
    }

    public var video: Video?
    /// Nil when the render source has no audio.
    public var audio: Audio?
    /// How long the whole export runs.
    public var duration: CMTime
}

/// A container writer fed with frames already encoded, such as the AVI
/// writer in MontageFormats. The export reads the render source, encodes it,
/// and calls these in order from a single task, video and audio interleaved
/// by time.
public protocol EncodedFrameSink: AnyObject {
    /// One encoded video frame, in presentation order (H.264 is encoded
    /// without B-frames, so decode order is the same). Its timestamps start at
    /// zero. H.264 frames are length-prefixed (AVCC), with the parameter sets
    /// in the sample buffer's format description; Motion JPEG frames are
    /// whole JPEG images.
    func appendVideo(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) throws
    /// Interleaved 16-bit little-endian PCM, as described by the stream's
    /// audio. Each call holds whole sample frames.
    func appendAudio(_ pcm: Data) throws
    /// Writes out what's left and closes the file.
    func finish() throws
    /// Stops writing; the export deletes the partial file afterwards.
    func cancel()
}

/// Makes a sink writing to a file. The app supplies one for AVI; without it,
/// AVI export isn't offered.
public typealias EncodedFrameSinkFactory = @Sendable (_ url: URL, _ streams: EncodedStreamDescription) throws -> any EncodedFrameSink
