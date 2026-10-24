@preconcurrency import AVFoundation
import Foundation
import VideoToolbox

/// Renders a render source for an AVI: reads it as preview plays it, encodes
/// the frames with VideoToolbox (Motion JPEG or H.264), keeps the audio as
/// 16-bit PCM, and hands both, interleaved by time, to a container writer.
struct AVIEncodingPipeline {
    let source: RenderSource
    let settings: ExportSettings
    let url: URL
    let makeSink: EncodedFrameSinkFactory
    let progress: @Sendable (Double) -> Void

    func run() async throws {
        let frameDuration = settings.frameRate.frameDuration(project: source.frameDuration)
        let render = try await RenderReader(source: source, frameDuration: frameDuration)
        let start = render.timeRange.start
        let outputSize = settings.resolution.size(for: source.renderSize)

        var videoProvider: RenderReader.Provider?
        if let output = render.videoOutput { videoProvider = render.reader.outputProvider(for: output) }
        var audioProvider: RenderReader.Provider?
        if let output = render.audioOutput { audioProvider = render.reader.outputProvider(for: output) }

        let video = videoProvider == nil ? nil : EncodedStreamDescription.Video(
            codec: settings.codec, width: Int(outputSize.width), height: Int(outputSize.height),
            frameDuration: frameDuration,
            averageBitRate: settings.videoBitRate(renderSize: source.renderSize, frameDuration: source.frameDuration)
        )
        let audio = audioProvider == nil ? nil : EncodedStreamDescription.Audio(
            sampleRate: Int(ExportSettings.audioSampleRate), channelCount: ExportSettings.audioChannelCount, bitsPerSample: 16
        )
        let streams = EncodedStreamDescription(video: video, audio: audio, duration: render.timeRange.duration)

        let encoder = try video.map { try VideoEncoder(stream: $0, quality: settings.quality) }
        let scaler = try FrameScaler(size: outputSize)
        let sink = try makeSink(url, streams)

        do {
            try render.reader.start()
            // Where each stream has got to, from the start of the export.
            var videoTime = CMTime.zero
            var audioTime = CMTime.zero
            var videoDone = videoProvider == nil
            var audioDone = audioProvider == nil

            // Read whichever stream is behind, so the two arrive interleaved
            // and the reader never waits on an output nobody is reading.
            while !videoDone || !audioDone {
                try Task.checkCancellation()
                if !videoDone, audioDone || videoTime <= audioTime, let provider = videoProvider, let encoder {
                    if let sample = try await provider.next() {
                        guard let frame = sample.pixelBuffer else { continue }
                        let time = sample.presentationTimeStamp - start
                        try encoder.encode(try scaler.scale(frame), at: time)
                        try encoder.drain(into: sink)
                        videoTime = time + frameDuration
                        progress(render.fraction(at: sample.presentationTimeStamp))
                    } else {
                        try encoder.finish()
                        try encoder.drain(into: sink)
                        videoDone = true
                    }
                } else if let provider = audioProvider {
                    if let sample = try await provider.next() {
                        let pcm = try sample.dataBytes()
                        if !pcm.isEmpty { try sink.appendAudio(pcm) }
                        let end = sample.presentationTimeStamp + sample.duration
                        audioTime = end - start
                        if videoProvider == nil { progress(render.fraction(at: end)) }
                    } else {
                        audioDone = true
                    }
                }
            }
            try render.checkFinished()
            try sink.finish()
        } catch {
            render.reader.cancelReading()
            sink.cancel()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if render.reader.status == .failed { throw ExportError.readFailed(render.reader.error) }
            throw error
        }
    }
}

/// A VideoToolbox compression session for AVI's video: one frame after
/// another, no B-frames, so frames come out in the order they went in.
final class VideoEncoder {
    private let session: VTCompressionSession
    private let output = EncodedOutput()
    private let frameDuration: CMTime

    init(stream: EncodedStreamDescription.Video, quality: ExportQuality) throws {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(stream.width), height: Int32(stream.height),
            codecType: stream.codec.codecType, encoderSpecification: nil, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw ExportError.encoderFailed(status) }
        self.session = session
        frameDuration = stream.frameDuration

        let frameRate = 1 / stream.frameDuration.seconds
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: frameRate as CFNumber)
        switch stream.codec {
        case .motionJPEG:
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality.jpegQuality as CFNumber)
        default:
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: stream.averageBitRate as CFNumber)
            VTSessionSetProperty(
                session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                value: max(Int((frameRate * 2).rounded()), 1) as CFNumber
            )
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit {
        VTCompressionSessionInvalidate(session)
    }

    func encode(_ frame: CVPixelBuffer, at time: CMTime) throws {
        let output = self.output
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: frame, presentationTimeStamp: time, duration: frameDuration,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sampleBuffer in
            output.append(status: status, sampleBuffer: sampleBuffer)
        }
        guard status == noErr else { throw ExportError.encoderFailed(status) }
    }

    /// Waits for every frame handed in so far to come out.
    func finish() throws {
        let status = VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        guard status == noErr else { throw ExportError.encoderFailed(status) }
    }

    /// Passes on the frames encoded so far.
    func drain(into sink: any EncodedFrameSink) throws {
        for sampleBuffer in try output.take() {
            try sink.appendVideo(sampleBuffer, isKeyframe: sampleBuffer.isKeyframe)
        }
    }
}

/// Encoded frames, as VideoToolbox hands them over on its own thread, until
/// the export takes them.
private final class EncodedOutput: @unchecked Sendable {
    // Guarded by the lock.
    private let lock = NSLock()
    private var frames: [CMSampleBuffer] = []
    private var failure: OSStatus = noErr

    func append(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        lock.withLock {
            if status != noErr {
                failure = status
            } else if let sampleBuffer {
                frames.append(sampleBuffer)
            }
        }
    }

    func take() throws -> [CMSampleBuffer] {
        try lock.withLock {
            guard failure == noErr else { throw ExportError.encoderFailed(failure) }
            defer { frames.removeAll() }
            return frames
        }
    }
}

extension CMSampleBuffer {
    /// Whether the frame decodes on its own.
    var isKeyframe: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }
}
