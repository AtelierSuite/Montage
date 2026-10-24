import AVFoundation
import CoreVideo
import Foundation
import os

/// A tiny black movie, made once and kept in the temporary folder, that
/// keeps a composition going under stills, text and shapes.
///
/// A composition only runs as long as its tracks, and a track can't end in
/// empty time, so a timeline that ends on a title, or holds nothing but
/// titles, would have nothing to play. The carrier is stretched along the
/// whole composition on a video track of its own, which the compositor
/// never draws, so its instructions cover every frame.
actor TimingCarrier {
    static let shared = TimingCarrier()

    /// How long the movie runs, before it's stretched.
    static let duration = CMTime(value: 1, timescale: 1)

    /// The movie being made, or made: every caller waits on the same one.
    private var made: Task<URL, Error>?

    static let logger = Logger(subsystem: "com.tsubuzaki.Montage", category: "TimingCarrier")

    /// The movie, made if it isn't there yet. Callers at the same time share
    /// one making of it; if it fails, or the file has gone since, the next
    /// call makes it again.
    func url() async throws -> URL {
        var failure: Error?
        for _ in 0..<2 {
            let task = made ?? {
                let task = Task { try await Self.make() }
                made = task
                return task
            }()
            do {
                let url = try await task.value
                if FileManager.default.fileExists(atPath: url.path) { return url }
            } catch {
                Self.logger.error("Couldn't make the timing carrier: \(error.localizedDescription, privacy: .public)")
                failure = error
            }
            // Unless another caller has already started again.
            if made == task { made = nil }
        }
        throw failure ?? CocoaError(.fileNoSuchFile)
    }

    private static func make() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "Montage Timing Carrier 1.mov")
        if FileManager.default.fileExists(atPath: url.path) {
            let asset = AVURLAsset(url: url)
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
               let range = try? await track.load(.timeRange), range.duration >= duration {
                return url
            }
            try? FileManager.default.removeItem(at: url)
        }
        // Written beside, then moved into place, so another process never
        // finds half a movie. Whatever happens, the partial file goes.
        let partial = FileManager.default.temporaryDirectory.appending(path: "Montage Timing Carrier \(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: partial) }
        let writer = try AVAssetWriter(outputURL: partial, fileType: .mov)
        let side = 64
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: side, AVVideoHeightKey: side,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: side, kCVPixelBufferHeightKey as String: side,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.startSession(atSourceTime: .zero)

        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, side, side, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard let buffer else { throw CocoaError(.fileWriteUnknown) }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        adaptor.append(buffer, withPresentationTime: .zero)
        input.markAsFinished()
        writer.endSession(atSourceTime: duration)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        do {
            try FileManager.default.moveItem(at: partial, to: url)
        } catch where FileManager.default.fileExists(atPath: url.path) {
            // Another process put its own there first, which is as good.
        }
        return url
    }
}
