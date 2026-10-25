import AVFoundation
import CoreMedia
import Foundation

/// The timecode a media file starts at, from its timecode track.
///
/// Cameras and editors stamp files with a start timecode, often 01:00:00:00
/// or the time of day, and edit decision lists give a file's in and out
/// points in that timecode rather than as time from the file's start.
public enum MediaTimecode {
    /// The time the file's first frame is stamped with, counted from
    /// 00:00:00:00 in the timecode track's own frames; nil for a file with
    /// no timecode track, or one that can't be read.
    @concurrent
    public static func start(of url: URL) async -> CMTime? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .timecode).first,
              let description = try? await track.load(.formatDescriptions).first,
              let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }
        defer { reader.cancelReading() }
        // The first buffers can be markers, such as an edit's boundary, with
        // no data in them.
        var dataBuffer: CMBlockBuffer?
        while dataBuffer == nil, let sample = output.copyNextSampleBuffer() {
            dataBuffer = CMSampleBufferGetDataBuffer(sample)
        }
        guard let buffer = dataBuffer else { return nil }

        let frameNumber: Int64
        switch CMFormatDescriptionGetMediaSubType(description) {
        case kCMTimeCodeFormatType_TimeCode32:
            guard let value = bigEndian(Int32.self, in: buffer) else { return nil }
            frameNumber = Int64(value)
        case kCMTimeCodeFormatType_TimeCode64:
            guard let value = bigEndian(Int64.self, in: buffer) else { return nil }
            frameNumber = value
        default:
            return nil
        }
        let frameDuration = CMTimeCodeFormatDescriptionGetFrameDuration(description)
        guard frameNumber >= 0, frameDuration.isNumeric, frameDuration > .zero else { return nil }
        let (value, overflow) = frameDuration.value.multipliedReportingOverflow(by: frameNumber)
        return overflow ? nil : CMTime(value: value, timescale: frameDuration.timescale)
    }

    private static func bigEndian<Value: FixedWidthInteger>(_ type: Value.Type, in buffer: CMBlockBuffer) -> Value? {
        let size = MemoryLayout<Value>.size
        guard CMBlockBufferGetDataLength(buffer) >= size else { return nil }
        var value: Value = 0
        let status = withUnsafeMutableBytes(of: &value) { bytes in
            CMBlockBufferCopyDataBytes(buffer, atOffset: 0, dataLength: size, destination: bytes.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? Value(bigEndian: value) : nil
    }
}

extension Project {
    /// Moves the source ranges of an item's clips back by `offset`, as when
    /// they were given in its timecode and it turns out to start at
    /// `offset`. Never before the media's start.
    public mutating func shiftSourceRanges(of id: MediaItem.ID, by offset: CMTime) {
        guard offset.isNumeric, offset != .zero else { return }
        for index in tracks.indices {
            for clip in tracks[index].clips where clip.content == .media(id) {
                tracks[index].update(clip.id) { clip in
                    clip.sourceRange.start = max(.zero, clip.sourceRange.start - offset)
                }
            }
        }
    }

    /// Moves an item's clips onto its file when their source ranges are in
    /// the file's timecode, which starts at `start`: when none of them fits
    /// in a file `duration` long as it is, and all of them do once counted
    /// from its timecode. Returns whether they were moved.
    ///
    /// This is how media brought in from an edit decision list, whose source
    /// points are timecode, lines up once it's relinked.
    @discardableResult
    public mutating func alignSourceRanges(of id: MediaItem.ID, toTimecodeStart start: CMTime, duration: CMTime) -> Bool {
        guard start.isNumeric, start > .zero, duration.isNumeric, duration > .zero else { return false }
        let ranges = tracks.flatMap(\.clips).filter { $0.content == .media(id) }.map(\.sourceRange)
        // A frame or so of slack for rounding.
        let slack = CMTime(value: 1, timescale: 10)
        let fitsAsIs = ranges.allSatisfy { $0.end <= duration + slack }
        let fitsTimecode = ranges.allSatisfy { $0.start >= start - slack && $0.end <= start + duration + slack }
        guard !ranges.isEmpty, !fitsAsIs, fitsTimecode else { return false }
        shiftSourceRanges(of: id, by: start)
        return true
    }
}
