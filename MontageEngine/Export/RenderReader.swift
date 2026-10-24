@preconcurrency import AVFoundation
import CoreMedia

/// Reads a render source the way preview plays it: video through its video
/// composition, audio through its audio mix, as uncompressed frames and PCM.
/// Both export paths start here, so MP4 and AVI render the same pictures.
///
/// It sets the reader up; the export asks the reader for a provider for each
/// output, then starts it.
struct RenderReader {
    typealias Provider = AVAssetReaderOutput.Provider<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>

    let reader: AVAssetReader
    let videoOutput: AVAssetReaderVideoCompositionOutput?
    let audioOutput: AVAssetReaderAudioMixOutput?
    /// The part of the source being read, in the source's time.
    let timeRange: CMTimeRange

    /// The PCM the audio is read as: what AVI stores as it is, and what the
    /// MP4 writer encodes to AAC.
    static let pcmSettings: [String: any Sendable] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: ExportSettings.audioSampleRate,
        AVNumberOfChannelsKey: ExportSettings.audioChannelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]

    init(source: RenderSource, frameDuration: CMTime) async throws {
        let asset = source.asset
        let timeRange = try await source.resolvedTimeRange()
        guard timeRange.duration > .zero else { throw ExportError.nothingToExport }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let videoComposition = try await source.exportVideoComposition(frameDuration: frameDuration)

        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = timeRange
        var videoOutput: AVAssetReaderVideoCompositionOutput?
        var audioOutput: AVAssetReaderAudioMixOutput?

        if let videoComposition, !videoTracks.isEmpty {
            let output = AVAssetReaderVideoCompositionOutput(videoTracks: videoTracks, videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: any Sendable](),
            ])
            output.videoComposition = videoComposition
            videoOutput = output
        }
        if !audioTracks.isEmpty {
            let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: Self.pcmSettings)
            output.audioMix = source.audioMix
            audioOutput = output
        }
        guard videoOutput != nil || audioOutput != nil else { throw ExportError.nothingToExport }

        self.reader = reader
        self.videoOutput = videoOutput
        self.audioOutput = audioOutput
        self.timeRange = timeRange
    }

    /// How far through the time range a sample at this time is, from 0 to 1.
    func fraction(at time: CMTime) -> Double {
        guard time.isNumeric, timeRange.duration.seconds > 0 else { return 0 }
        return min(max((time - timeRange.start).seconds / timeRange.duration.seconds, 0), 1)
    }

    /// Throws the reader's error if it stopped before the end.
    func checkFinished() throws {
        if reader.status == .failed { throw ExportError.readFailed(reader.error) }
    }
}

extension CMReadySampleBuffer<CMSampleBuffer.DynamicContent> {
    /// The frame's pixels, for a video sample.
    var pixelBuffer: CVPixelBuffer? {
        withUnsafeSampleBuffer { buffer in
            // The frame is the reader's to hand out: nothing else holds it
            // once the sample buffer has been read.
            nonisolated(unsafe) let image = buffer.imageBuffer
            return image
        }
    }

    /// The sample's bytes, for an audio sample.
    func dataBytes() throws -> Data {
        try withUnsafeSampleBuffer { buffer in
            guard let data = buffer.dataBuffer else { return Data() }
            return try data.dataBytes()
        }
    }
}
