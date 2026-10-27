import AVFoundation
import CoreVideo
import Foundation

/// Writes short movies at test time, of a size and turn made to order.
enum TestMovie {
    struct WriteError: Error {}

    /// A second of black frames at 30 fps, `width` by `height` as stored,
    /// turned a quarter clockwise to show with `quarterTurn`, and with a
    /// timecode track numbering its first frame `timecode` where given.
    static func write(to url: URL, width: Int, height: Int, quarterTurn: Bool = false, timecode: Int32? = nil) async throws {
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
        var firstTimecode: CMSampleBuffer?
        var timecodeInput: AVAssetWriterInput?
        if let timecode {
            let sample = try Self.timecodeSample(numbering: timecode, frames: frameCount)
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: sample.formatDescription)
            writer.add(input)
            video.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue)
            firstTimecode = sample
            timecodeInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? WriteError() }
        writer.startSession(atSourceTime: .zero)
        // The timecode goes first, so the writer isn't left waiting for it.
        if let timecodeInput, let firstTimecode {
            while !timecodeInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            guard timecodeInput.append(firstTimecode) else { throw writer.error ?? WriteError() }
            timecodeInput.markAsFinished()
        }

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

    /// One timecode sample, lasting the whole movie: its first frame's
    /// number, big-endian, counted at 30 fps.
    private static func timecodeSample(numbering frame: Int32, frames: Int) throws -> CMSampleBuffer {
        var description: CMTimeCodeFormatDescription?
        CMTimeCodeFormatDescriptionCreate(
            allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32, frameDuration: CMTime(value: 1, timescale: 30),
            frameQuanta: 30, flags: 0, extensions: nil, formatDescriptionOut: &description
        )
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        )
        guard let description, let block else { throw WriteError() }
        var number = frame.bigEndian
        CMBlockBufferReplaceDataBytes(with: &number, blockBuffer: block, offsetIntoDestination: 0, dataLength: 4)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: Int64(frames), timescale: 30), presentationTimeStamp: .zero, decodeTimeStamp: .invalid
        )
        var size = 4
        var sample: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: block, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
            formatDescription: description, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
        )
        guard let sample else { throw WriteError() }
        return sample
    }
}
