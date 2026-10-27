import AVFoundation
import CoreVideo
import Foundation

/// Writes short movies at test time, of a size and turn made to order.
enum TestMovie {
    struct WriteError: Error {}

    /// A second of black frames at 30 fps, `width` by `height` as stored,
    /// turned a quarter clockwise to show with `quarterTurn`.
    static func write(to url: URL, width: Int, height: Int, quarterTurn: Bool = false) async throws {
        let frameCount = 30
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        video.expectsMediaDataInRealTime = false
        if quarterTurn { video.transform = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0) }
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(video)
        guard writer.startWriting() else { throw writer.error ?? WriteError() }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
                  let buffer, adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? WriteError()
            }
        }
        video.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? WriteError() }
    }
}
