import Foundation
import Synchronization

/// Writes an AVI file from frames that are already encoded, streaming them to
/// disk as they're appended.
///
/// AVFoundation can't write AVI, so this lays out the RIFF container itself:
/// OpenDML (AVI 2.0), so files can go past 1 GB, while the first gigabyte
/// stays readable by AVI 1.0 players. It holds one video stream, Motion JPEG
/// or H.264, and optionally one stream of 16-bit PCM audio.
///
/// Append frames in order, one per frame duration: AVI has no timestamps of
/// its own, so a frame's place in the file is its time. Append audio as it
/// comes; it's held back and interleaved with the video it plays alongside,
/// in chunks of up to half a second. Then call ``finish()``, which writes the
/// indexes and headers. A writer that's released without finishing leaves an
/// incomplete file behind; call ``cancel()`` and delete it instead.
///
/// - Motion JPEG frames are each a complete baseline JPEG image (from `FFD8`
///   to `FFD9`), as from ImageIO or a `VTCompressionSession` for
///   `kCMVideoCodecType_JPEG`, at the size in ``VideoSettings``. Every frame
///   is a keyframe.
/// - H.264 frames are one access unit each, as an Annex B byte stream (start
///   codes rather than length prefixes), with the SPS and PPS in front of every
///   keyframe. ``appendVideo(_:)`` converts the length-prefixed frames a
///   `VTCompressionSession` makes into this. Turn off frame reordering
///   (`kVTCompressionPropertyKey_AllowFrameReordering`), since AVI keeps
///   frames in one order and many players don't reorder B-frames in it.
/// - Audio is 16-bit signed little-endian PCM with the channels interleaved,
///   at the rate and channel count in ``AudioSettings``.
///
/// Every call does blocking file I/O, so use a writer from a background task
/// or queue, not the main actor. Calls are serialized by a lock, so it's safe
/// to call from a `VTCompressionSession`'s output handler, but frames are
/// written in the order the calls arrive: feed each stream from one place.
public final class AVIWriter: Sendable {
    private let muxer: Mutex<AVIMuxer>

    /// Creates the file at `url`, replacing any file there, and writes
    /// placeholder headers.
    public convenience init(url: URL, video: VideoSettings, audio: AudioSettings? = nil) throws {
        try self.init(url: url, video: video, audio: audio, segmentLimit: AVIMuxer.defaultSegmentLimit)
    }

    /// Creates a writer whose segments close before `segmentLimit` bytes,
    /// so tests can reach a second segment without writing a gigabyte.
    init(url: URL, video: VideoSettings, audio: AudioSettings?, segmentLimit: Int) throws {
        muxer = Mutex(try AVIMuxer(url: url, video: video, audio: audio, segmentLimit: segmentLimit))
    }

    public var videoSettings: VideoSettings { muxer.withLock { $0.video } }
    public var audioSettings: AudioSettings? { muxer.withLock { $0.audio } }

    /// The number of video frames appended so far, for reporting progress.
    public var framesWritten: Int { muxer.withLock { $0.framesWritten } }

    /// Appends the next video frame, encoded as the stream's codec expects.
    /// Motion JPEG frames are always keyframes, whatever `isKeyframe` says.
    public func appendVideoFrame(_ frame: Data, isKeyframe: Bool) throws {
        try muxer.withLock { muxer in
            try muxer.appendVideoFrame(frame, isKeyframe: isKeyframe || muxer.video.codec == .motionJPEG)
        }
    }

    /// Appends audio that follows on from the audio appended before: 16-bit
    /// signed little-endian samples, the channels interleaved, and a whole
    /// number of samples for every channel.
    public func appendAudio(_ pcm: Data) throws {
        try muxer.withLock { try $0.appendAudio(pcm) }
    }

    /// Writes the audio still held back, the indexes and the final headers,
    /// and closes the file.
    public func finish() throws {
        try muxer.withLock { try $0.finish() }
    }

    /// Stops writing and closes the file, leaving it incomplete.
    public func cancel() {
        muxer.withLock { $0.cancel() }
    }
}
