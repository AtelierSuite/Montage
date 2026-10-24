import CoreMedia
import Foundation
@testable import MontageFormats
import Synchronization
import Testing

@Suite struct AVIWriterTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "AVIWriterTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    // The suite is a struct, so clean up from a scope rather than deinit.
    func removeDirectory() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Motion JPEG

    @Test func writesMotionJPEGWithAudio() throws {
        defer { removeDirectory() }
        let url = directory.appending(path: "mjpeg.avi")
        let frameRate = AVIWriter.FrameRate(30000, 1001)
        let video = AVIWriter.VideoSettings(codec: .motionJPEG, width: 320, height: 240, frameRate: frameRate)
        let audio = AVIWriter.AudioSettings(sampleRate: 48000, channels: 2)
        let writer = try AVIWriter(url: url, video: video, audio: audio)

        // Audio arrives in blocks of its own size, as from a reader, a little
        // ahead of the frames it plays with.
        let frames = 45
        let totalSamples = frames * 48000 * 1001 / 30000
        var samplesAppended = 0
        for frame in 0..<frames {
            let due = min(totalSamples, (frame + 4) * 48000 * 1001 / 30000)
            while samplesAppended < due {
                let count = min(1024, due - samplesAppended)
                try writer.appendAudio(TestMedia.sine(samples: count, from: samplesAppended, sampleRate: 48000, channels: 2))
                samplesAppended += count
            }
            let jpeg = TestMedia.jpeg(TestMedia.image(width: 320, height: 240, frame: frame))
            try writer.appendVideoFrame(jpeg, isKeyframe: false)
        }
        #expect(writer.framesWritten == frames)
        try writer.finish()

        let layout = try AVILayout(RIFFFile(url: url), video: video, audio: audio)
        #expect(layout.segments == 1)
        #expect(layout.videoFrames == frames)
        #expect(layout.keyframes == frames)
        #expect(layout.audioSamples == totalSamples)
        #expect(layout.largestAudioDrift <= 0.6)
        // One chunk of audio before each frame, rather than one per block appended.
        #expect(layout.audioChunks == frames)
        #expect(layout.videoPrefixes.allSatisfy { $0.starts(with: [0xFF, 0xD8]) })

        try expectFFmpegReads(url, codec: "mjpeg", tag: "MJPG", video: video, frames: frames, audio: audio, audioSamples: totalSamples)
    }

    // MARK: H.264

    @Test func writesH264FromVideoToolbox() throws {
        defer { removeDirectory() }
        let url = directory.appending(path: "h264.avi")
        let frameRate = AVIWriter.FrameRate(30)
        let video = AVIWriter.VideoSettings(codec: .h264, width: 320, height: 240, frameRate: frameRate)
        let audio = AVIWriter.AudioSettings(sampleRate: 44100, channels: 1)
        let writer = try AVIWriter(url: url, video: video, audio: audio)

        // The encoder hands frames over on its own thread, straight to the writer.
        let frames = 60
        let failure = Mutex<(any Error)?>(nil)
        try TestMedia.encodeH264(width: 320, height: 240, frames: frames, frameRate: frameRate, keyframeInterval: 15) { sampleBuffer in
            do {
                try writer.appendVideo(sampleBuffer)
            } catch {
                failure.withLock { $0 = error }
            }
        }
        try failure.withLock { if let error = $0 { throw error } }

        let totalSamples = 44100 * frames / 30
        for start in stride(from: 0, to: totalSamples, by: 4096) {
            let pcm = TestMedia.sine(samples: min(4096, totalSamples - start), from: start, sampleRate: 44100, channels: 1)
            try writer.appendAudio(TestMedia.pcmSampleBuffer(pcm, sampleRate: 44100, channels: 1))
        }
        try writer.finish()

        let layout = try AVILayout(RIFFFile(url: url), video: video, audio: audio)
        #expect(layout.videoFrames == frames)
        #expect(layout.keyframes == frames / 15)
        #expect(layout.audioSamples == totalSamples)
        // Keyframes lead with an SPS, after a start code; every frame starts with one.
        #expect(layout.videoPrefixes.allSatisfy { $0.starts(with: H264AnnexB.startCode) })
        #expect(layout.keyframePrefixes.allSatisfy { $0.count > 4 && $0[$0.startIndex + 4] & 0x1F == 7 })

        try expectFFmpegReads(url, codec: "h264", tag: "H264", video: video, frames: frames, audio: audio, audioSamples: totalSamples)
    }

    @Test func rewritesLengthPrefixedNALUnitsAsAnnexB() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1E])
        let pps = Data([0x68, 0xCE, 0x3C, 0x80])
        let slice = Data([0x65, 0x88, 0x84, 0x00])
        let avcc = Data([0, 0, 0, 4]) + slice + Data([0, 0, 0, 2, 0x06, 0x05])

        let units = try H264AnnexB.nalUnits(in: avcc, lengthSize: 4)
        #expect(units == [slice, Data([0x06, 0x05])])
        let start = Data(H264AnnexB.startCode)
        let withParameterSets: [Data] = [start, sps, start, pps, start, slice, start, Data([0x06, 0x05])]
        #expect(H264AnnexB.annexB(units, parameterSets: [sps, pps]) == withParameterSets.reduce(Data(), +))
        // A frame that carries its own SPS doesn't get a second.
        let withOwnSPS: [Data] = [start, sps, start, slice]
        #expect(H264AnnexB.annexB([sps, slice], parameterSets: [sps, pps]) == withOwnSPS.reduce(Data(), +))

        #expect(throws: AVIWriterError.unsupportedMedia) {
            try H264AnnexB.nalUnits(in: Data([0, 0, 0, 9, 0x65]), lengthSize: 4)
        }
    }

    // MARK: OpenDML

    @Test func continuesInAVIXSegments() throws {
        defer { removeDirectory() }
        let url = directory.appending(path: "segments.avi")
        let video = AVIWriter.VideoSettings(codec: .motionJPEG, width: 320, height: 240, frameRate: .init(25))
        let audio = AVIWriter.AudioSettings(sampleRate: 22050, channels: 1)
        let limit = 200_000
        let writer = try AVIWriter(url: url, video: video, audio: audio, segmentLimit: limit)

        let frames = 120
        for frame in 0..<frames {
            try writer.appendAudio(TestMedia.sine(samples: 882, from: frame * 882, sampleRate: 22050, channels: 1))
            try writer.appendVideoFrame(TestMedia.jpeg(TestMedia.image(width: 320, height: 240, frame: frame), quality: 0.95), isKeyframe: true)
        }
        try writer.finish()

        let file = try RIFFFile(url: url)
        let layout = try AVILayout(file, video: video, audio: audio)
        #expect(layout.segments >= 3)
        #expect(file.chunks.allSatisfy { $0.size <= limit })
        #expect(layout.videoFrames == frames)
        #expect(layout.audioSamples == frames * 882)
        #expect(layout.firstSegmentFrames < frames)

        try expectFFmpegReads(url, codec: "mjpeg", tag: "MJPG", video: video, frames: frames, audio: audio, audioSamples: frames * 882)
    }

    @Test func stopsWhenTheSuperIndexIsFull() throws {
        defer { removeDirectory() }
        let url = directory.appending(path: "full.avi")
        let video = AVIWriter.VideoSettings(codec: .motionJPEG, width: 16, height: 16, frameRate: .init(30))
        // Every frame goes in a segment of its own.
        let writer = try AVIWriter(url: url, video: video, audio: nil, segmentLimit: 1)
        let jpeg = TestMedia.jpeg(TestMedia.image(width: 16, height: 16, frame: 0))

        for _ in 0..<AVIMuxer.superIndexCapacity {
            try writer.appendVideoFrame(jpeg, isKeyframe: true)
        }
        #expect(throws: AVIWriterError.tooLarge) {
            try writer.appendVideoFrame(jpeg, isKeyframe: true)
        }
        // What was written before is still a whole file.
        try writer.finish()
        let layout = try AVILayout(RIFFFile(url: url), video: video, audio: nil)
        #expect(layout.segments == AVIMuxer.superIndexCapacity)
        #expect(layout.videoFrames == AVIMuxer.superIndexCapacity)
        try expectFFmpegReads(url, codec: "mjpeg", tag: "MJPG", video: video, frames: layout.videoFrames, audio: nil)
    }

    // MARK: Errors

    @Test func rejectsWhatAVICantHold() throws {
        defer { removeDirectory() }
        let url = directory.appending(path: "errors.avi")
        let video = AVIWriter.VideoSettings(codec: .motionJPEG, width: 64, height: 64, frameRate: .init(24))

        #expect(throws: AVIWriterError.invalidSettings) {
            try AVIWriter(url: url, video: .init(codec: .h264, width: 0, height: 64, frameRate: .init(24)))
        }
        #expect(throws: AVIWriterError.invalidSettings) {
            try AVIWriter(url: url, video: .init(codec: .h264, width: 64, height: 64, frameRate: .init(0)))
        }
        #expect(throws: AVIWriterError.invalidSettings) {
            try AVIWriter(url: url, video: video, audio: .init(sampleRate: 48000, channels: 6))
        }

        let silent = try AVIWriter(url: url, video: video)
        #expect(throws: AVIWriterError.unsupportedMedia) { try silent.appendAudio(Data(count: 4)) }
        silent.cancel()

        let writer = try AVIWriter(url: url, video: video, audio: .init(sampleRate: 48000, channels: 2))
        #expect(throws: AVIWriterError.unsupportedMedia) { try writer.appendAudio(Data(count: 6)) }
        let mono = try TestMedia.pcmSampleBuffer(Data(count: 8), sampleRate: 48000, channels: 1)
        #expect(throws: AVIWriterError.unsupportedMedia) { try writer.appendAudio(mono) }
        try writer.finish()
        #expect(throws: AVIWriterError.notWriting) { try writer.appendVideoFrame(Data([0xFF, 0xD8]), isKeyframe: true) }
        #expect(throws: AVIWriterError.notWriting) { try writer.finish() }

        for error in [AVIWriterError.invalidSettings, .unsupportedMedia, .tooLarge, .notWriting] {
            let description = try #require(error.errorDescription)
            #expect(!description.hasPrefix("AVIWriter.Error."))
        }
    }

    @Test func readsFrameRatesFromFrameDurations() {
        #expect(AVIWriter.FrameRate(frameDuration: CMTime(value: 1001, timescale: 30000)) == .init(30000, 1001))
        #expect(AVIWriter.FrameRate(frameDuration: .invalid) == nil)
        #expect(AVIWriter.FrameRate(frameDuration: .zero) == nil)
    }

    // MARK: Large files

    /// Writes past 1 GB, so the file needs AVIX segments at their real size.
    /// Set `MONTAGE_LARGE_FILE_TESTS` to run it (for `xcodebuild test`, as
    /// `TEST_RUNNER_MONTAGE_LARGE_FILE_TESTS=1`).
    @Test(.tags(.largeFile), .enabled(if: ProcessInfo.processInfo.environment["MONTAGE_LARGE_FILE_TESTS"] != nil))
    func writesPastOneGigabyte() throws {
        defer { removeDirectory() }
        let url = directory.appending(path: "large.avi")
        let video = AVIWriter.VideoSettings(codec: .motionJPEG, width: 1920, height: 1080, frameRate: .init(30000, 1001))
        let audio = AVIWriter.AudioSettings(sampleRate: 48000, channels: 2)
        let writer = try AVIWriter(url: url, video: video, audio: audio)

        let jpeg = TestMedia.noiseJPEG(width: 1920, height: 1080)
        let frames = 2_300_000_000 / jpeg.count + 1
        let samplesPerFrame = 48000 * 1001 / 30000
        let pcm = TestMedia.sine(samples: samplesPerFrame, sampleRate: 48000, channels: 2)
        for _ in 0..<frames {
            try writer.appendAudio(pcm)
            try writer.appendVideoFrame(jpeg, isKeyframe: true)
        }
        try writer.finish()

        let file = try RIFFFile(url: url)
        #expect(file.fileSize > 2_300_000_000)
        let layout = try AVILayout(file, video: video, audio: audio)
        #expect(layout.segments >= 3)
        #expect(file.chunks.allSatisfy { $0.size <= AVIMuxer.defaultSegmentLimit })
        #expect(layout.videoFrames == frames)
        #expect(layout.audioSamples == frames * samplesPerFrame)

        guard FFmpeg.isAvailable else { return }
        let (probe, errors) = try FFmpeg.probe(url, countFrames: false)
        #expect(errors.isEmpty, "\(errors)")
        #expect(probe.stream("video")?["nb_read_packets"] as? String == "\(frames)")
        let duration = Double(frames) * 1001 / 30000
        #expect(abs(probe.duration - duration) < 0.05)
    }

    // MARK: Checking with FFmpeg

    private func expectFFmpegReads(
        _ url: URL, codec: String, tag: String, video: AVIWriter.VideoSettings, frames: Int,
        audio: AVIWriter.AudioSettings?, audioSamples: Int = 0
    ) throws {
        guard FFmpeg.isAvailable else { return }
        let (probe, errors) = try FFmpeg.probe(url)
        #expect(errors.isEmpty, "\(errors)")
        #expect(probe.formatName == "avi")
        let duration = Double(frames) * Double(video.frameRate.denominator) / Double(video.frameRate.numerator)
        #expect(abs(probe.duration - duration) < 0.05, "\(probe.duration) against \(duration)")

        let stream = try #require(probe.stream("video"))
        #expect(stream["codec_name"] as? String == codec)
        #expect(stream["codec_tag_string"] as? String == tag)
        #expect(stream["width"] as? Int == video.width)
        #expect(stream["height"] as? Int == video.height)
        #expect(stream["r_frame_rate"] as? String == "\(video.frameRate.numerator)/\(video.frameRate.denominator)")
        #expect(stream["nb_frames"] as? String == "\(frames)")
        #expect(stream["nb_read_frames"] as? String == "\(frames)")

        if let audio {
            let stream = try #require(probe.stream("audio"))
            #expect(stream["codec_name"] as? String == "pcm_s16le")
            #expect(stream["sample_rate"] as? String == "\(audio.sampleRate)")
            #expect(stream["channels"] as? Int == audio.channels)
            // ffprobe gives PCM in AVI no duration of its own, but counts its samples.
            #expect(stream["nb_frames"] as? String == "\(audioSamples)")
        }

        let decodeErrors = try FFmpeg.decodeErrors(url)
        #expect(decodeErrors.isEmpty, "\(decodeErrors)")
    }
}

/// An AVI file's structure, read back and checked against itself: that the
/// segments fill the file, the headers count what the segments hold, and
/// every index entry lands on the chunk it describes.
struct AVILayout {
    var segments = 0
    var firstSegmentFrames = 0
    var videoFrames = 0
    var keyframes = 0
    var audioSamples = 0
    var audioChunks = 0
    var videoPrefixes: [Data] = []
    var keyframePrefixes: [Data] = []
    /// The furthest audio got from the video, in seconds, through the file.
    var largestAudioDrift = 0.0

    init(_ file: RIFFFile, video: AVIWriter.VideoSettings, audio: AVIWriter.AudioSettings?) throws {
        let rate = video.frameRate
        let frameDuration = Double(rate.denominator) / Double(rate.numerator)

        // Segments: RIFF 'AVI ', then RIFF 'AVIX', filling the file.
        let riffs = file.chunks
        try #require(riffs.allSatisfy { $0.id == "RIFF" })
        try #require(riffs.first?.listType == "AVI ")
        #expect(riffs.dropFirst().allSatisfy { $0.listType == "AVIX" })
        #expect(riffs.reduce(0) { $0 + 8 + UInt64($1.size) + UInt64($1.size % 2) } == file.fileSize)
        segments = riffs.count

        let first = riffs[0]
        let hdrl = try #require(first.child("LIST", type: "hdrl"))
        let avih = try #require(hdrl.child("avih"))
        let strls = hdrl.children("LIST").filter { $0.listType == "strl" }
        #expect(strls.count == (audio == nil ? 1 : 2))
        #expect(avih.u32(at: 24) == UInt32(strls.count))
        #expect(avih.u32(at: 32) == UInt32(video.width))
        #expect(avih.u32(at: 36) == UInt32(video.height))

        let firstMovi = try #require(first.child("LIST", type: "movi"))
        #expect(firstMovi.offset % 4096 == 0)
        #expect(first.child("JUNK") != nil)

        // Every chunk of media, by where its header starts.
        var media: [UInt64: RIFFChunk] = [:]
        var drift = 0.0
        var audioSeconds = 0.0
        var frames = 0
        for riff in riffs {
            let movi = try #require(riff.child("LIST", type: "movi"))
            for chunk in movi.children where chunk.isMedia {
                media[chunk.offset] = chunk
                if chunk.id == "00dc" {
                    frames += 1
                    videoPrefixes.append(chunk.data)
                } else if let audio {
                    #expect(chunk.id == "01wb")
                    audioChunks += 1
                    audioSeconds += Double(Int(chunk.size) / audio.blockAlign) / Double(audio.sampleRate)
                }
                drift = max(drift, abs(audioSeconds - Double(frames) * frameDuration))
            }
        }
        largestAudioDrift = drift

        // The AVI 1.0 index covers the first segment, from its 'movi' code.
        let idx1 = try #require(first.child("idx1"))
        let firstMedia = firstMovi.children.filter(\.isMedia)
        #expect(idx1.data.count == 16 * firstMedia.count)
        for (entry, chunk) in zip(0..<idx1.data.count / 16, firstMedia) {
            #expect(idx1.fourCC(at: entry * 16) == chunk.id)
            #expect(firstMovi.dataOffset + UInt64(idx1.u32(at: entry * 16 + 8)) == chunk.offset)
            #expect(idx1.u32(at: entry * 16 + 12) == chunk.size)
        }
        firstSegmentFrames = firstMedia.filter { $0.id == "00dc" }.count
        #expect(avih.u32(at: 16) == UInt32(firstSegmentFrames))

        // The total, across segments.
        let dmlh = try #require(hdrl.child("LIST", type: "odml")?.child("dmlh"))
        #expect(dmlh.u32(at: 0) == UInt32(frames))

        // Each stream's super index lists one standard index per segment.
        let indexes = riffs.flatMap { $0.child("LIST", type: "movi")?.children ?? [] }.filter { $0.id.hasPrefix("ix") }
        for (number, strl) in strls.enumerated() {
            let strh = try #require(strl.child("strh"))
            let strf = try #require(strl.child("strf"))
            let indx = try #require(strl.child("indx"))
            let chunkID = number == 0 ? "00dc" : "01wb"
            #expect(indx.u16(at: 0) == 4)
            #expect(indx.fourCC(at: 8) == chunkID)

            var duration = 0
            var keys = 0
            for entry in 0..<Int(indx.u32(at: 4)) {
                let base = 24 + entry * 16
                let index = try #require(indexes.first { $0.offset == indx.u64(at: base) })
                #expect(index.id == String(format: "ix%02d", number))
                #expect(indx.u32(at: base + 8) == index.size + 8)
                #expect(index.u16(at: 0) == 2)
                #expect(index.data[index.data.startIndex + 3] == 1)
                #expect(index.fourCC(at: 8) == chunkID)
                let moviBase = index.u64(at: 12)
                let count = Int(index.u32(at: 4))
                var segmentDuration = 0
                for item in 0..<count {
                    let offset = moviBase + UInt64(index.u32(at: 24 + item * 8)) - 8
                    let sizeAndFlag = index.u32(at: 28 + item * 8)
                    let chunk = try #require(media[offset])
                    #expect(chunk.id == chunkID)
                    #expect(chunk.size == sizeAndFlag & 0x7FFF_FFFF)
                    if sizeAndFlag & 0x8000_0000 == 0 {
                        keys += 1
                        if number == 0 { keyframePrefixes.append(chunk.data) }
                    }
                    segmentDuration += number == 0 ? 1 : Int(chunk.size) / (audio?.blockAlign ?? 1)
                }
                #expect(indx.u32(at: base + 12) == UInt32(segmentDuration))
                duration += segmentDuration
            }

            if number == 0 {
                #expect(strh.fourCC(at: 0) == "vids")
                #expect(strh.fourCC(at: 4) == video.codec.fourCC)
                #expect(strh.u32(at: 20) == rate.denominator)
                #expect(strh.u32(at: 24) == rate.numerator)
                #expect(strh.u32(at: 32) == UInt32(frames))
                #expect(strf.fourCC(at: 16) == video.codec.fourCC)
                #expect(duration == frames)
                videoFrames = frames
                keyframes = keys
            } else if let audio {
                #expect(strh.fourCC(at: 0) == "auds")
                #expect(strh.u32(at: 20) == UInt32(audio.blockAlign))
                #expect(strh.u32(at: 24) == UInt32(audio.bytesPerSecond))
                #expect(strh.u32(at: 32) == UInt32(duration))
                #expect(strf.u16(at: 0) == 1)
                #expect(strf.u16(at: 2) == UInt16(audio.channels))
                #expect(strf.u32(at: 4) == UInt32(audio.sampleRate))
                #expect(strf.u16(at: 14) == 16)
                audioSamples = duration
            }
        }
    }
}
