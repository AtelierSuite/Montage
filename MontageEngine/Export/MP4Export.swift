@preconcurrency import AVFoundation
import CoreVideo
import Synchronization
import VideoToolbox

/// Writes a render source to an MP4: H.264 or HEVC at the settings' bit
/// rate, AAC audio, with the index at the front so it plays as it downloads.
struct MP4Export {
    let source: RenderSource
    let settings: ExportSettings
    let url: URL
    let progress: @Sendable (Double) -> Void

    func run() async throws {
        let frameDuration = settings.frameRate.frameDuration(project: source.frameDuration)
        let render = try await RenderReader(source: source, frameDuration: frameDuration)
        let timeRange = render.timeRange
        let outputSize = settings.resolution.size(for: source.renderSize)
        let progress = self.progress

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        var videoProvider: RenderReader.Provider?
        var videoReceiver: AVAssetWriterInput.PixelBufferReceiver?
        if let output = render.videoOutput {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(size: outputSize))
            guard writer.canAdd(input) else { throw ExportError.writeFailed(writer.error) }
            videoReceiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
            videoProvider = render.reader.outputProvider(for: output)
        }
        var audioProvider: RenderReader.Provider?
        var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
        if let output = render.audioOutput {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.audioSettings)
            guard writer.canAdd(input) else { throw ExportError.writeFailed(writer.error) }
            audioReceiver = writer.inputReceiver(for: input)
            audioProvider = render.reader.outputProvider(for: output)
        }
        let hasVideo = videoProvider != nil
        let stopper = Stopper(reader: render.reader, writer: writer)

        do {
            try render.reader.start()
            try writer.start()
            writer.startSession(atSourceTime: timeRange.start)

            // Video and audio each go at their own pace: the writer holds one
            // back while it waits for the other to interleave them. So when
            // either stops early, or the export is cancelled, the reader and
            // writer are stopped too, or the other would wait for good.
            //
            // Each reads on a queue of its own: reading blocks its thread
            // until the reader has the next sample, and the reader can hold
            // one output back until the other is read. On the shared threads,
            // enough exports at once would leave no thread to read the other,
            // and every one of them would wait for good.
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup { group in
                    if let videoProvider, let videoReceiver {
                        group.addTask(executorPreference: DispatchQueue(label: "Montage.Export.Video")) { try await stopper.stoppingOnFailure {
                            let scaler = try FrameScaler(size: outputSize)
                            while let sample = try await videoProvider.next() {
                                try Task.checkCancellation()
                                guard let frame = sample.pixelBuffer else { continue }
                                let time = sample.presentationTimeStamp
                                // A new buffer from the scaler's pool, or the
                                // reader's own frame; either way, no one else's.
                                nonisolated(unsafe) let scaled = try scaler.scale(frame)
                                try await videoReceiver.append(CVReadOnlyPixelBuffer(unsafeBuffer: scaled), with: time)
                                progress(Self.fraction(of: timeRange, at: time))
                            }
                            videoReceiver.finish()
                        } }
                    }
                    if let audioProvider, let audioReceiver {
                        group.addTask(executorPreference: DispatchQueue(label: "Montage.Export.Audio")) { try await stopper.stoppingOnFailure {
                            while let sample = try await audioProvider.next() {
                                try Task.checkCancellation()
                                let time = sample.presentationTimeStamp
                                try await audioReceiver.append(sample)
                                if !hasVideo { progress(Self.fraction(of: timeRange, at: time)) }
                            }
                            audioReceiver.finish()
                        } }
                    }
                    try await group.waitForAll()
                }
            } onCancel: {
                stopper.stop()
            }
            try Task.checkCancellation()
            try render.checkFinished()

            await writer.finishWriting()
            guard writer.status == .completed else { throw ExportError.writeFailed(writer.error) }
        } catch {
            stopper.stop()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if writer.status == .failed { throw ExportError.writeFailed(writer.error) }
            if render.reader.status == .failed { throw ExportError.readFailed(render.reader.error) }
            throw error
        }
    }

    /// Stops reading and writing from whichever task notices first, once:
    /// both tasks, cancellation and the export itself can all stop it, and
    /// the reader crashes when it's cancelled twice at once.
    private final class Stopper: @unchecked Sendable {
        // AVAssetReader and AVAssetWriter can be cancelled from any thread.
        private let reader: AVAssetReader
        private let writer: AVAssetWriter
        private let hasStopped = Mutex(false)

        init(reader: AVAssetReader, writer: AVAssetWriter) {
            self.reader = reader
            self.writer = writer
        }

        func stop() {
            let isFirst = hasStopped.withLock { hasStopped in
                defer { hasStopped = true }
                return !hasStopped
            }
            guard isFirst else { return }
            reader.cancelReading()
            if writer.status == .writing { writer.cancelWriting() }
        }

        func stoppingOnFailure(_ body: () async throws -> Void) async throws {
            do {
                try await body()
            } catch {
                stop()
                throw error
            }
        }
    }

    static func fraction(of timeRange: CMTimeRange, at time: CMTime) -> Double {
        guard time.isNumeric, timeRange.duration.seconds > 0 else { return 0 }
        return min(max((time - timeRange.start).seconds / timeRange.duration.seconds, 0), 1)
    }

    private func videoSettings(size: CGSize) -> [String: any Sendable] {
        let frameRate = 1 / settings.frameRate.frameDuration(project: source.frameDuration).seconds
        var compression: [String: any Sendable] = [
            AVVideoAverageBitRateKey: settings.videoBitRate(renderSize: source.renderSize, frameDuration: source.frameDuration),
            AVVideoExpectedSourceFrameRateKey: frameRate,
            // A keyframe every two seconds, so scrubbing the file is quick.
            AVVideoMaxKeyFrameIntervalKey: max(Int((frameRate * 2).rounded()), 1),
        ]
        let codec: AVVideoCodecType
        switch settings.codec {
        case .hevc:
            codec = .hevc
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        default:
            codec = .h264
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }
        return [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    private static let audioSettings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: ExportSettings.audioSampleRate,
        AVNumberOfChannelsKey: ExportSettings.audioChannelCount,
        AVEncoderBitRateKey: ExportSettings.aacBitRate,
    ]
}
