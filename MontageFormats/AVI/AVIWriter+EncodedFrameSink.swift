import CoreMedia
import Foundation
import MontageEngine

/// The AVI writer as the container behind the exporter's AVI pipeline.
extension AVIWriter: EncodedFrameSink {
    public func appendVideo(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) throws {
        // The writer reads whether it's a keyframe from the sample buffer.
        try appendVideo(sampleBuffer)
    }

    /// Makes AVI writers for `Exporter`, set up for the streams it encodes.
    public static let encodedFrameSinkFactory: EncodedFrameSinkFactory = { url, streams in
        guard let video = streams.video, let frameRate = FrameRate(frameDuration: video.frameDuration) else {
            throw AVIWriterError.invalidSettings
        }
        let codec: VideoSettings.Codec
        switch video.codec {
        case .motionJPEG: codec = .motionJPEG
        case .h264: codec = .h264
        case .hevc: throw AVIWriterError.invalidSettings
        }
        let audio = streams.audio.map { AudioSettings(sampleRate: $0.sampleRate, channels: min($0.channelCount, 2)) }
        return try AVIWriter(
            url: url, video: VideoSettings(codec: codec, width: video.width, height: video.height, frameRate: frameRate),
            audio: audio
        )
    }
}
