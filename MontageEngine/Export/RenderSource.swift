@preconcurrency import AVFoundation
import CoreMedia

/// What an export renders: an asset with the video composition and audio mix
/// that preview plays it with, so the file matches what the user saw.
///
/// For a project this is what `CompositionBuilder` makes of it; for tests it
/// can be a plain file, optionally with a hand-made video composition.
public struct RenderSource: @unchecked Sendable {
    // AVAsset, AVVideoComposition and AVAudioMix are immutable once made, and
    // nothing here hands out a mutable one.

    public var asset: AVAsset
    /// How the video tracks are drawn into each frame. Without one, the
    /// asset's own video is used as it is.
    public var videoComposition: AVVideoComposition?
    /// How loud each audio track is, over time.
    public var audioMix: AVAudioMix?
    /// The size the video composition draws at, in pixels. The export scales
    /// from it to the size the user picked.
    public var renderSize: CGSize
    /// How long each frame lasts in the project.
    public var frameDuration: CMTime
    /// The part to export. Nil exports the whole asset.
    public var timeRange: CMTimeRange?

    public init(
        asset: AVAsset, videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil,
        renderSize: CGSize, frameDuration: CMTime, timeRange: CMTimeRange? = nil
    ) {
        self.asset = asset
        self.videoComposition = videoComposition
        self.audioMix = audioMix
        self.renderSize = renderSize
        self.frameDuration = frameDuration
        self.timeRange = timeRange
    }

    /// The project as preview plays it: the very composition, video
    /// composition and audio mix the player is given.
    public init(_ built: BuiltComposition) {
        self.init(
            asset: built.composition, videoComposition: built.videoComposition, audioMix: built.audioMix,
            renderSize: built.videoComposition?.renderSize ?? built.project.settings.renderSize,
            frameDuration: built.project.settings.frameDuration,
            timeRange: CMTimeRange(start: .zero, duration: built.duration)
        )
    }

    /// A source for a plain media file, sized and timed as its video track is.
    public static func file(at url: URL, timeRange: CMTimeRange? = nil) async throws -> RenderSource {
        let asset = AVURLAsset(url: url)
        var renderSize = CGSize(width: 1920, height: 1080)
        var frameDuration = CMTime(value: 1, timescale: 30)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let (naturalSize, transform, frameRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
            let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
            renderSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            if frameRate > 0 { frameDuration = CMTime(seconds: 1 / Double(frameRate), preferredTimescale: 600) }
        }
        return RenderSource(asset: asset, renderSize: renderSize, frameDuration: frameDuration, timeRange: timeRange)
    }
}

/// What the app tells whoever builds a render source about the conditions it
/// will be rendered in.
public struct RenderContext: Sendable {
    /// Whether the GPU can be used for the whole export. On iOS, an export
    /// that carries on in the background may lose the GPU where the device or
    /// the app can't keep it; the composition should then render on the CPU.
    public var allowsGPU: Bool

    public init(allowsGPU: Bool = true) {
        self.allowsGPU = allowsGPU
    }
}

extension RenderSource {
    /// The time range that will be exported.
    func resolvedTimeRange() async throws -> CMTimeRange {
        let duration = try await asset.load(.duration)
        let full = CMTimeRange(start: .zero, duration: duration)
        guard let timeRange else { return full }
        return timeRange.intersection(full)
    }

    /// The video composition to read through: the source's own, with frames
    /// at the export's rate, or one made from the asset's video tracks.
    func exportVideoComposition(frameDuration: CMTime) async throws -> AVVideoComposition? {
        guard !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { return nil }
        var configuration: AVVideoComposition.Configuration
        if let videoComposition {
            configuration = AVVideoComposition.Configuration(videoComposition: videoComposition)
        } else {
            configuration = try await AVVideoComposition.Configuration(for: asset)
            configuration.renderSize = renderSize
        }
        configuration.frameDuration = frameDuration
        // Frames at the export's steady rate, not following a source track's.
        configuration.sourceTrackIDForFrameTiming = kCMPersistentTrackID_Invalid
        return AVVideoComposition(configuration: configuration)
    }
}

extension AVVideoComposition.Configuration {
    /// A configuration that makes the same composition as this one.
    init(videoComposition: AVVideoComposition) {
        self.init(
            animationTool: videoComposition.animationTool,
            colorPrimaries: videoComposition.colorPrimaries,
            colorTransferFunction: videoComposition.colorTransferFunction,
            colorYCbCrMatrix: videoComposition.colorYCbCrMatrix,
            customVideoCompositorClass: videoComposition.customVideoCompositorClass,
            frameDuration: videoComposition.frameDuration,
            instructions: videoComposition.instructions,
            outputBufferDescription: videoComposition.outputBufferDescription,
            perFrameHDRDisplayMetadataPolicy: videoComposition.perFrameHDRDisplayMetadataPolicy,
            renderScale: videoComposition.renderScale,
            renderSize: videoComposition.renderSize,
            sourceSampleDataTrackIDs: videoComposition.sourceSampleDataTrackIDs,
            sourceTrackIDForFrameTiming: videoComposition.sourceTrackIDForFrameTiming,
            spatialVideoConfigurations: videoComposition.spatialVideoConfigurations
        )
    }
}
