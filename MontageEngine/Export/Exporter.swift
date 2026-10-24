@preconcurrency import AVFoundation
import Foundation

/// Why an export stopped.
public enum ExportError: Error, Sendable {
    /// The render source has no video or audio in the range asked for.
    case nothingToExport
    /// AVI was asked for, but no AVI writer was supplied.
    case formatUnavailable(ExportFormat)
    /// The codec can't go in the format.
    case codecUnsupported(ExportVideoCodec, ExportFormat)
    case readFailed((any Error)?)
    case writeFailed((any Error)?)
    case encoderFailed(OSStatus)
}

/// Renders a render source to a file.
///
/// Both formats read the source through `AVAssetReader`, with its video
/// composition and audio mix (see `RenderReader`), rather than through
/// `AVAssetExportSession`:
///
/// - An export session only offers fixed presets: no bit rate or quality
///   control, a handful of sizes (no 720p HEVC, nothing for portrait or
///   unusual project sizes) and no way to choose the frame rate apart from
///   the video composition. Export options are part of #32.
/// - AVI can't be written by an export session at all, and needs the frames
///   read through the same composition anyway. With one reader for both
///   formats, MP4 and AVI render exactly the same pictures and sound.
///
/// MP4 is then written with `AVAssetWriter`, which encodes H.264 or HEVC at
/// the chosen bit rate and the audio as AAC. AVI is encoded with
/// VideoToolbox and handed to an `EncodedFrameSink`.
///
/// Exports run on whatever task calls `export`, off the main actor, and stop
/// when the task is cancelled. The output file is removed whenever an export
/// doesn't finish.
public struct Exporter: Sendable {
    /// Makes the AVI writer. Without it, AVI exports fail with
    /// `formatUnavailable`.
    public var aviSinkFactory: EncodedFrameSinkFactory?

    public init(aviSinkFactory: EncodedFrameSinkFactory? = nil) {
        self.aviSinkFactory = aviSinkFactory
    }

    /// Whether this exporter can write the format.
    public func supports(_ format: ExportFormat) -> Bool {
        switch format {
        case .mp4: true
        case .avi: aviSinkFactory != nil
        }
    }

    /// Renders the source to a file at `url`, replacing what's there.
    ///
    /// - Parameter progress: Called as the export goes, with how much of it
    ///   is done, from 0 to 1, from whichever thread the export is on.
    public func export(
        _ source: RenderSource, settings: ExportSettings, to url: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard settings.format.videoCodecs.contains(settings.codec) else {
            throw ExportError.codecUnsupported(settings.codec, settings.format)
        }
        try? FileManager.default.removeItem(at: url)
        do {
            switch settings.format {
            case .mp4:
                try await MP4Export(source: source, settings: settings, url: url, progress: progress).run()
            case .avi:
                guard let aviSinkFactory else { throw ExportError.formatUnavailable(.avi) }
                try await AVIEncodingPipeline(
                    source: source, settings: settings, url: url, makeSink: aviSinkFactory, progress: progress
                ).run()
            }
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: url)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
        progress(1)
    }
}
