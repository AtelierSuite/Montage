import Foundation

/// Lays out an AVI file as chunks arrive, streaming them to disk.
///
/// The file is OpenDML (AVI 2.0), and stays readable by AVI 1.0 players up to
/// its first gigabyte:
///
///     RIFF 'AVI '                     the first segment, up to about 1 GB
///     ├── LIST 'hdrl'                 headers, rewritten in place on finish
///     │   ├── avih                    main header
///     │   ├── LIST 'strl'             one per stream
///     │   │   ├── strh, strf          stream header and format
///     │   │   └── indx                super index: one entry per segment
///     │   └── LIST 'odml' → dmlh      total frames across every segment
///     ├── LIST 'INFO' → ISFT          the writing application
///     ├── JUNK                        rounds the headers up to 4 KB
///     ├── LIST 'movi'
///     │   ├── 00dc, 01wb, …           video frames and audio, interleaved
///     │   └── ix00, ix01              standard index of this segment's chunks
///     └── idx1                        AVI 1.0 index of the first segment
///     RIFF 'AVIX'                     further segments, when there's more
///     └── LIST 'movi' → …, ix00, ix01
///
/// The headers have a fixed size, since the super index reserves room for
/// every segment it can describe, so finishing rewrites them over the
/// placeholders written at the start without moving anything.
struct AVIMuxer {
    /// Each segment closes before it grows past this, the size AVI 1.0
    /// readers and most OpenDML ones expect.
    static let defaultSegmentLimit = 1 << 30
    /// Segments a super index has room for, so a file can reach about 256 GB.
    static let superIndexCapacity = 256
    static let headerAlignment = 4096
    static let applicationName = "Montage"

    /// Audio is written in chunks of at most this many seconds.
    static let audioChunkDuration = 0.5

    private struct IndexEntry {
        /// Where the chunk's data starts, from the segment's `movi` code.
        var dataOffset: UInt32
        var size: UInt32
        var isKeyframe: Bool
    }

    private struct LegacyIndexEntry {
        var stream: Int
        var isKeyframe: Bool
        /// Where the chunk's header starts, from the first `movi` code.
        var offset: UInt32
        var size: UInt32
    }

    private struct SuperIndexEntry {
        var offset: UInt64
        var size: UInt32
        var duration: UInt32
    }

    private struct Stream {
        let chunkID: String
        let indexID: String
        /// In the stream's own units: frames for video, samples for audio.
        var length = 0
        var largestChunk = 0
        var segmentEntries: [IndexEntry] = []
        var segmentDuration = 0
        var superIndex: [SuperIndexEntry] = []

        init(number: Int, type: String) {
            chunkID = String(format: "%02d", number) + type
            indexID = "ix" + String(format: "%02d", number)
        }
    }

    let video: AVIWriter.VideoSettings
    let audio: AVIWriter.AudioSettings?
    private let segmentLimit: Int
    private let handle: FileHandle

    private var streams: [Stream]
    private var position = 0
    private var segmentNumber = 0
    private var riffStart = 0
    private var moviListStart = 0
    private var legacyIndex: [LegacyIndexEntry] = []
    private var firstSegmentSize = 0
    private var firstSegmentFrames = 0
    private var dataBytes = 0

    /// Audio waiting to be interleaved with the video it plays alongside.
    private var pendingAudio = Data()
    private(set) var isWriting = true

    private static let videoStream = 0
    private static let audioStream = 1

    init(url: URL, video: AVIWriter.VideoSettings, audio: AVIWriter.AudioSettings?, segmentLimit: Int) throws {
        guard video.isValid, audio?.isValid ?? true else { throw AVIWriterError.invalidSettings }
        self.video = video
        self.audio = audio
        self.segmentLimit = segmentLimit
        streams = [Stream(number: 0, type: "dc")]
        if audio != nil { streams.append(Stream(number: 1, type: "wb")) }

        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: url])
        }
        handle = try FileHandle(forWritingTo: url)

        let header = makeHeader()
        try write(header)
        moviListStart = position
        try write(Self.listStart("movi"))
    }

    var framesWritten: Int { streams[Self.videoStream].length }

    // MARK: Appending

    mutating func appendVideoFrame(_ frame: Data, isKeyframe: Bool) throws {
        try checkWriting()
        // The audio that plays with this frame goes just before it.
        try flushAudio(.through(frames: framesWritten + 1))
        try writeChunk(stream: Self.videoStream, payload: frame, isKeyframe: isKeyframe, duration: 1)
    }

    mutating func appendAudio(_ pcm: Data) throws {
        try checkWriting()
        guard let audio else { throw AVIWriterError.unsupportedMedia }
        guard pcm.count % audio.blockAlign == 0 else { throw AVIWriterError.unsupportedMedia }
        pendingAudio.append(pcm)
        try flushAudio(.overflow)
    }

    mutating func finish() throws {
        try checkWriting()
        try flushAudio(.all)
        try closeSegment()
        try handle.seek(toOffset: 0)
        try write(makeHeader())
        isWriting = false
        try handle.close()
    }

    /// Closes the file as it is, without finishing it.
    mutating func cancel() {
        guard isWriting else { return }
        isWriting = false
        try? handle.close()
    }

    private func checkWriting() throws {
        guard isWriting else { throw AVIWriterError.notWriting }
    }

    // MARK: Interleaving

    private var audioChunkLimit: Int {
        guard let audio else { return 0 }
        return max(1, Int(Double(audio.sampleRate) * Self.audioChunkDuration)) * audio.blockAlign
    }

    private enum AudioFlush {
        /// Only what's run more than a chunk ahead, keeping what's held back
        /// bounded when audio arrives well before the video.
        case overflow
        /// Also the audio that plays up to the end of this many frames.
        case through(frames: Int)
        /// Everything left.
        case all
    }

    /// Writes held-back audio, in chunks of up to `audioChunkLimit`.
    private mutating func flushAudio(_ flush: AudioFlush) throws {
        guard let audio, !pendingAudio.isEmpty else { return }
        let limit = audioChunkLimit
        let rate = video.frameRate
        let dueBytes = switch flush {
        case .overflow: 0
        case .through(let frames):
            (frames * audio.sampleRate * Int(rate.denominator) + Int(rate.numerator) - 1) / Int(rate.numerator)
                * audio.blockAlign
        case .all: Int.max
        }
        var written = streams[Self.audioStream].length * audio.blockAlign

        while !pendingAudio.isEmpty {
            let count: Int
            if pendingAudio.count > 2 * limit {
                count = limit
            } else if written < dueBytes {
                count = min(limit, pendingAudio.count, dueBytes - written)
            } else {
                break
            }
            let chunk = Data(pendingAudio.prefix(count))
            pendingAudio.removeFirst(count)
            try writeChunk(stream: Self.audioStream, payload: chunk, isKeyframe: true, duration: count / audio.blockAlign)
            written += count
        }
    }

    // MARK: Chunks and segments

    private var moviBase: Int { moviListStart + 8 }

    private mutating func writeChunk(stream: Int, payload: Data, isKeyframe: Bool, duration: Int) throws {
        guard payload.count < Int(UInt32.max / 2) else { throw AVIWriterError.tooLarge }
        let chunkSize = 8 + payload.count + payload.count % 2
        try makeRoom(for: chunkSize, in: stream)

        let offset = position
        var header = RIFFData()
        header.fourCC(streams[stream].chunkID)
        header.u32(UInt32(payload.count))
        try write(header.data)
        try write(payload)
        if payload.count % 2 == 1 { try write(Data([0])) }

        streams[stream].segmentEntries.append(IndexEntry(
            dataOffset: UInt32(offset + 8 - moviBase), size: UInt32(payload.count), isKeyframe: isKeyframe))
        if segmentNumber == 0 {
            legacyIndex.append(LegacyIndexEntry(
                stream: stream, isKeyframe: isKeyframe, offset: UInt32(offset - moviBase), size: UInt32(payload.count)))
        }
        streams[stream].segmentDuration += duration
        streams[stream].length += duration
        streams[stream].largestChunk = max(streams[stream].largestChunk, payload.count)
        dataBytes += payload.count
    }

    /// Starts a new segment when the chunk wouldn't fit in this one, leaving
    /// room for the indexes that close it.
    private mutating func makeRoom(for chunkSize: Int, in stream: Int) throws {
        guard streams.contains(where: { !$0.segmentEntries.isEmpty }) else { return }
        var closingSize = 0
        for (number, other) in streams.enumerated() {
            let entries = other.segmentEntries.count + (number == stream ? 1 : 0)
            if entries > 0 { closingSize += 32 + 8 * entries }
        }
        if segmentNumber == 0 { closingSize += 8 + 16 * (legacyIndex.count + 1) }
        guard position + chunkSize + closingSize - riffStart > segmentLimit else { return }

        // The new segment needs a super index entry beyond the closing one.
        guard streams.allSatisfy({ $0.superIndex.count + 2 <= Self.superIndexCapacity }) else {
            throw AVIWriterError.tooLarge
        }
        try closeSegment()
        segmentNumber += 1
        riffStart = position
        var riff = RIFFData()
        riff.fourCC("RIFF")
        riff.u32(0)
        riff.fourCC("AVIX")
        try write(riff.data)
        moviListStart = position
        try write(Self.listStart("movi"))
    }

    /// Ends the segment with its standard indexes, and, for the first, the
    /// AVI 1.0 index, then fills in the segment's sizes.
    private mutating func closeSegment() throws {
        for number in streams.indices where !streams[number].segmentEntries.isEmpty {
            let stream = streams[number]
            let offset = position
            var index = RIFFData()
            index.chunk(stream.indexID) { index in
                index.u16(2) // wLongsPerEntry
                index.u8(0) // bIndexSubType
                index.u8(1) // bIndexType: AVI_INDEX_OF_CHUNKS
                index.u32(UInt32(stream.segmentEntries.count))
                index.fourCC(stream.chunkID)
                index.u64(UInt64(moviBase)) // qwBaseOffset
                index.u32(0)
                for entry in stream.segmentEntries {
                    index.u32(entry.dataOffset)
                    // The top bit marks chunks that aren't keyframes.
                    index.u32(entry.size | (entry.isKeyframe ? 0 : 0x8000_0000))
                }
            }
            try write(index.data)
            streams[number].superIndex.append(SuperIndexEntry(
                offset: UInt64(offset), size: UInt32(index.count), duration: UInt32(stream.segmentDuration)))
            streams[number].segmentEntries = []
            streams[number].segmentDuration = 0
        }
        try patch(UInt32(position - moviBase), at: moviListStart + 4)

        if segmentNumber == 0 {
            var index = RIFFData()
            index.chunk("idx1") { index in
                for entry in legacyIndex {
                    index.fourCC(streams[entry.stream].chunkID)
                    index.u32(entry.isKeyframe ? 0x10 : 0) // AVIIF_KEYFRAME
                    index.u32(entry.offset)
                    index.u32(entry.size)
                }
            }
            try write(index.data)
            legacyIndex = []
            firstSegmentFrames = framesWritten
            firstSegmentSize = position - 8
        } else {
            try patch(UInt32(position - riffStart - 8), at: riffStart + 4)
        }
    }

    // MARK: Headers

    private static func listStart(_ type: String) -> Data {
        var list = RIFFData()
        list.fourCC("LIST")
        list.u32(0)
        list.fourCC(type)
        return list.data
    }

    /// The first segment's `RIFF` header through to the `JUNK` before its
    /// `movi` list, as it stands now. It's the same size every time.
    private func makeHeader() -> Data {
        let rate = video.frameRate
        let frames = framesWritten
        let duration = Double(frames) * Double(rate.denominator) / Double(rate.numerator)
        let width = UInt32(video.width)
        let height = UInt32(video.height)

        var header = RIFFData()
        header.fourCC("RIFF")
        header.u32(UInt32(firstSegmentSize))
        header.fourCC("AVI ")
        header.list("hdrl") { hdrl in
            hdrl.chunk("avih") { avih in
                avih.u32(UInt32((1_000_000 * Double(rate.denominator) / Double(rate.numerator)).rounded()))
                avih.u32(duration > 0 ? UInt32(min(Double(UInt32.max), Double(dataBytes) / duration)) : 0)
                avih.u32(0) // dwPaddingGranularity
                avih.u32(0x10 | 0x100 | 0x800) // AVIF_HASINDEX | AVIF_ISINTERLEAVED | AVIF_TRUSTCKTYPE
                avih.u32(UInt32(firstSegmentFrames)) // frames in the first segment only
                avih.u32(0) // dwInitialFrames
                avih.u32(UInt32(streams.count))
                avih.u32(UInt32(streams.map(\.largestChunk).max() ?? 0))
                avih.u32(width)
                avih.u32(height)
                avih.zeros(16)
            }
            hdrl.list("strl") { strl in
                let stream = streams[Self.videoStream]
                strl.chunk("strh") { strh in
                    strh.fourCC("vids")
                    strh.fourCC(video.codec.fourCC)
                    strh.u32(0) // dwFlags
                    strh.u16(0) // wPriority
                    strh.u16(0) // wLanguage
                    strh.u32(0) // dwInitialFrames
                    strh.u32(rate.denominator) // dwScale
                    strh.u32(rate.numerator) // dwRate
                    strh.u32(0) // dwStart
                    strh.u32(UInt32(stream.length))
                    strh.u32(UInt32(stream.largestChunk))
                    strh.u32(UInt32.max) // dwQuality: default
                    strh.u32(0) // dwSampleSize: frames vary in size
                    strh.i16(0)
                    strh.i16(0)
                    strh.i16(Int16(video.width))
                    strh.i16(Int16(video.height))
                }
                strl.chunk("strf") { strf in
                    // BITMAPINFOHEADER
                    strf.u32(40)
                    strf.u32(width)
                    strf.u32(height)
                    strf.u16(1) // biPlanes
                    strf.u16(24) // biBitCount
                    strf.fourCC(video.codec.fourCC)
                    strf.u32(width * height * 3) // biSizeImage
                    strf.u32(0)
                    strf.u32(0)
                    strf.u32(0)
                    strf.u32(0)
                }
                Self.writeSuperIndex(stream, into: &strl)
            }
            if let audio {
                hdrl.list("strl") { strl in
                    let stream = streams[Self.audioStream]
                    strl.chunk("strh") { strh in
                        strh.fourCC("auds")
                        strh.u32(0) // fccHandler
                        strh.u32(0)
                        strh.u16(0)
                        strh.u16(0)
                        strh.u32(0)
                        strh.u32(UInt32(audio.blockAlign)) // dwScale
                        strh.u32(UInt32(audio.bytesPerSecond)) // dwRate
                        strh.u32(0)
                        strh.u32(UInt32(stream.length)) // in samples
                        strh.u32(UInt32(stream.largestChunk))
                        strh.u32(UInt32.max)
                        strh.u32(UInt32(audio.blockAlign)) // dwSampleSize
                        strh.zeros(8)
                    }
                    strl.chunk("strf") { strf in
                        // WAVEFORMATEX
                        strf.u16(1) // WAVE_FORMAT_PCM
                        strf.u16(UInt16(audio.channels))
                        strf.u32(UInt32(audio.sampleRate))
                        strf.u32(UInt32(audio.bytesPerSecond))
                        strf.u16(UInt16(audio.blockAlign))
                        strf.u16(UInt16(AVIWriter.AudioSettings.bytesPerSample * 8))
                        strf.u16(0) // cbSize
                    }
                    Self.writeSuperIndex(stream, into: &strl)
                }
            }
            hdrl.list("odml") { odml in
                odml.chunk("dmlh") { dmlh in
                    dmlh.u32(UInt32(frames))
                    dmlh.zeros(244)
                }
            }
        }
        header.list("INFO") { info in
            info.chunk("ISFT") { isft in
                isft.bytes(Array(Self.applicationName.utf8) + [0])
            }
        }
        let used = header.count + 8
        let aligned = (used + Self.headerAlignment - 1) / Self.headerAlignment * Self.headerAlignment
        header.chunk("JUNK") { $0.zeros(aligned - used) }
        return header.data
    }

    private static func writeSuperIndex(_ stream: Stream, into list: inout RIFFData) {
        list.chunk("indx") { indx in
            indx.u16(4) // wLongsPerEntry
            indx.u8(0) // bIndexSubType
            indx.u8(0) // bIndexType: AVI_INDEX_OF_INDEXES
            indx.u32(UInt32(stream.superIndex.count))
            indx.fourCC(stream.chunkID)
            indx.zeros(12)
            for entry in stream.superIndex {
                indx.u64(entry.offset)
                indx.u32(entry.size)
                indx.u32(entry.duration)
            }
            indx.zeros(16 * (superIndexCapacity - stream.superIndex.count))
        }
    }

    // MARK: File

    /// Writes at the end of the file, or wherever it was moved to. Once
    /// writing fails, the file is closed and the writer takes nothing more.
    private mutating func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            cancel()
            throw error
        }
        position += data.count
    }

    private mutating func patch(_ value: UInt32, at offset: Int) throws {
        var bytes = RIFFData()
        bytes.u32(value)
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: bytes.data)
            try handle.seek(toOffset: UInt64(position))
        } catch {
            cancel()
            throw error
        }
    }
}
