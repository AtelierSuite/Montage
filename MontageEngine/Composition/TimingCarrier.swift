import AVFoundation
import CoreVideo
import Foundation

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

    private var made: Task<URL, Error>?

    /// The movie, made if it isn't there yet.
    func url() async throws -> URL {
        if let made {
            if let url = try? await made.value, FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let task = Task { try await Self.make() }
        made = task
        return try await task.value
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
        // finds half a movie.
        let partial = FileManager.default.temporaryDirectory.appending(path: "Montage Timing Carrier \(UUID().uuidString).mov")
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
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: partial, to: url)
        return url
    }
}
