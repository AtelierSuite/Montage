import AVFoundation
import Foundation

/// The timecode a movie's frames are numbered by, from its timecode track,
/// which cameras and other editors write and Montage otherwise passes over.
enum MediaTimecode {
    /// The time the timecode gives the movie's first frame, or nil when it
    /// has no timecode track.
    static func start(of url: URL) async -> CMTime? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        // Past the markers of edits, which hold no samples.
        var next = output.copyNextSampleBuffer()
        while let sample = next, sample.numSamples == 0 { next = output.copyNextSampleBuffer() }
        guard let sample = next, let description = sample.formatDescription, let data = sample.dataBuffer else { return nil }

        // The first sample holds the first frame's number, big-endian.
        let length = switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMTimeCodeFormatType_TimeCode32: 4
        case kCMTimeCodeFormatType_TimeCode64: 8
        default: 0
        }
        guard length > 0, CMBlockBufferGetDataLength(data) >= length else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
        let frames = length == 4
            ? Int64(Int32(bitPattern: bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }))
            : Int64(bitPattern: bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        // A frame number counts every frame, dropped-frame timecode's too.
        let frame = CMTimeCodeFormatDescriptionGetFrameDuration(description)
        guard frames >= 0, frame.isNumeric, frame > .zero else { return nil }
        return CMTime(value: frame.value * frames, timescale: frame.timescale)
    }
}
