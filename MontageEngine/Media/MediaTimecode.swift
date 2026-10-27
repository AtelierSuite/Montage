import AVFoundation
import CoreMedia
import Foundation

/// The timecode a media file starts at.
///
/// Cameras and editors stamp files with a start timecode, often 01:00:00:00
/// or the time of day, and edit decision lists give a file's in and out
/// points in that timecode rather than as time from the file's start.
/// Movies carry it in a timecode track, and Broadcast WAV recordings as the
/// samples since midnight in their `bext` chunk.
public struct MediaTimecode: Equatable, Sendable {
    /// The time the file's first frame is stamped with, counted from
    /// 00:00:00:00.
    public var time: CMTime
    /// The stamp as the timecode counts it, in frames, where it counts
    /// frames: a timecode track does, a Broadcast WAV's time reference
    /// doesn't.
    public var frames: Frames?

    public struct Frames: Equatable, Sendable {
        /// Frames from 00:00:00:00.
        public var number: Int64
        /// How long each of the timecode's frames lasts: 1001/30000 for 29.97.
        public var frameDuration: CMTime
        public var isDropFrame: Bool

        public init(number: Int64, frameDuration: CMTime, isDropFrame: Bool) {
            self.number = number
            self.frameDuration = frameDuration
            self.isDropFrame = isDropFrame
        }
    }

    public init(time: CMTime, frames: Frames? = nil) {
        self.time = time
        self.frames = frames
    }

    /// The timecode a file starts at; nil for a file with none, or one
    /// that can't be read.
    @concurrent
    public static func start(of url: URL) async -> MediaTimecode? {
        await start(of: AVURLAsset(url: url))
    }

    /// The timecode an asset's file starts at, from its timecode track, or
    /// for a WAV file with none, its Broadcast WAV time reference.
    static func start(of asset: AVURLAsset) async -> MediaTimecode? {
        if let track = try? await asset.loadTracks(withMediaType: .timecode).first {
            return await start(of: track, in: asset)
        }
        return BroadcastWAV.timeReference(of: asset.url)
    }

    private static func start(of track: AVAssetTrack, in asset: AVAsset) async -> MediaTimecode? {
        guard let description = try? await track.load(.formatDescriptions).first,
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
        guard !overflow else { return nil }
        let isDropFrame = CMTimeCodeFormatDescriptionGetTimeCodeFlags(description) & kCMTimeCodeFlag_DropFrame != 0
        return MediaTimecode(
            time: CMTime(value: value, timescale: frameDuration.timescale),
            frames: Frames(number: frameNumber, frameDuration: frameDuration, isDropFrame: isDropFrame)
        )
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

extension MediaTimecode: Codable {
    private enum CodingKeys: String, CodingKey {
        case time, frames
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(CMTime.self, forKey: .time)
        frames = try container.decodeIfPresent(Frames.self, forKey: .frames)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encodeIfPresent(frames, forKey: .frames)
    }
}

extension MediaTimecode.Frames: Codable {
    private enum CodingKeys: String, CodingKey {
        case number, frameDuration, isDropFrame
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = try container.decode(Int64.self, forKey: .number)
        frameDuration = try container.decode(CMTime.self, forKey: .frameDuration)
        isDropFrame = try container.decode(Bool.self, forKey: .isDropFrame)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(number, forKey: .number)
        try container.encode(frameDuration, forKey: .frameDuration)
        try container.encode(isDropFrame, forKey: .isDropFrame)
    }
}

/// The time reference of a Broadcast WAV file: the samples from midnight
/// to its first, in its `bext` chunk, counted at the rate in its `fmt `.
enum BroadcastWAV {
    static func timeReference(of url: URL) -> MediaTimecode? {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              ["RIFF", "RF64", "BW64"].contains(String(decoding: header.prefix(4), as: UTF8.self)),
              String(decoding: header.suffix(4), as: UTF8.self) == "WAVE" else { return nil }

        var sampleRate: UInt32?
        var samples: UInt64?
        // The chunks before the sound, skipping over it if they come after.
        while sampleRate == nil || samples == nil,
              let chunk = try? handle.read(upToCount: 8), chunk.count == 8 {
            let id = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = UInt64(littleEndian(UInt32.self, in: chunk, at: 4))
            guard let start = try? handle.offset() else { return nil }
            switch id {
            case "fmt " where size >= 8:
                guard let body = try? handle.read(upToCount: 8), body.count == 8 else { return nil }
                sampleRate = littleEndian(UInt32.self, in: body, at: 4)
            case "bext" where size >= 346:
                guard let body = try? handle.read(upToCount: 346), body.count == 346 else { return nil }
                samples = UInt64(littleEndian(UInt32.self, in: body, at: 338))
                    | UInt64(littleEndian(UInt32.self, in: body, at: 342)) << 32
            default:
                break
            }
            // An RF64 file's sound can be bigger than its chunk says.
            if id == "data", size == 0xFFFF_FFFF { break }
            // Chunks are padded to an even length.
            guard (try? handle.seek(toOffset: start + size + size % 2)) != nil else { return nil }
        }
        guard let sampleRate, sampleRate > 0, let samples, samples <= UInt64(Int64.max) else { return nil }
        return MediaTimecode(time: CMTime(value: Int64(samples), timescale: CMTimeScale(sampleRate)))
    }

    private static func littleEndian<Value: FixedWidthInteger>(_ type: Value.Type, in data: Data, at offset: Int) -> Value {
        var value: Value = 0
        withUnsafeMutableBytes(of: &value) { bytes in
            bytes.copyBytes(from: data[data.startIndex + offset ..< data.startIndex + offset + MemoryLayout<Value>.size])
        }
        return Value(littleEndian: value)
    }
}

extension Project {
    /// Moves an item's clips onto its file, when their source ranges were
    /// given in its timecode, as an edit decision list gives them, and its
    /// timecode starts at `offset`: each is moved back by `offset`.
    ///
    /// If none of them starts at or after `offset`, they can't be in the
    /// timecode, and are taken as time from the file's start, as some
    /// editors write them, and left as they are. Returns the clips that
    /// start before the file does, as they were, which are moved to its
    /// first frame.
    @discardableResult
    public mutating func moveSourceRanges(of id: MediaItem.ID, ontoFileStartingAt offset: CMTime) -> [Clip] {
        guard offset.isNumeric, offset > .zero else { return [] }
        let clips = tracks.flatMap(\.clips).filter { $0.content == .media(id) }
        guard clips.contains(where: { $0.sourceRange.start >= offset }) else { return [] }
        for index in tracks.indices {
            for clip in tracks[index].clips where clip.content == .media(id) {
                tracks[index].update(clip.id) { clip in
                    clip.sourceRange.start = max(.zero, clip.sourceRange.start - offset)
                }
            }
        }
        return clips.filter { $0.sourceRange.start < offset }
    }
}
