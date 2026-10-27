import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// Media stamped with a start timecode, as camera files are, against the
/// source points of an edit decision list, which are given in it.
@Suite(.timeLimit(.minutes(1)))
struct EDLSourceTimecodeTests {
    private func seconds(_ value: Int64, _ timescale: Int32 = 1) -> CMTime {
        CMTime(value: value, timescale: timescale)
    }

    /// A 3 second, 30 fps movie in a fresh folder, with a timecode track
    /// starting at `startFrame`, or none.
    private func makeMovie(named name: String, startFrame: Int32?) async throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EDLSourceTimecode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64,
        ])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(video)

        let frameDuration = CMTime(value: 1, timescale: 30)
        var timecodeInput: AVAssetWriterInput?
        var timecodeFormat: CMTimeCodeFormatDescription?
        if startFrame != nil {
            try #require(CMTimeCodeFormatDescriptionCreate(
                allocator: nil, timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32, frameDuration: frameDuration,
                frameQuanta: 30, flags: kCMTimeCodeFlag_24HourMax, extensions: nil, formatDescriptionOut: &timecodeFormat
            ) == noErr)
            let input = AVAssetWriterInput(mediaType: .timecode, outputSettings: nil, sourceFormatHint: timecodeFormat)
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            video.addTrackAssociation(withTrackOf: input, type: AVAssetTrack.AssociationType.timecode.rawValue)
            timecodeInput = input
        }

        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        // The timecode's one sample first, so the writer isn't left waiting
        // on it while the frames go in.
        if let input = timecodeInput, let startFrame, let timecodeFormat {
            var number = startFrame.bigEndian
            var block: CMBlockBuffer?
            try #require(CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: 4, blockAllocator: nil, customBlockSource: nil,
                offsetToData: 0, dataLength: 4, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
            ) == kCMBlockBufferNoErr)
            let data = try #require(block)
            CMBlockBufferReplaceDataBytes(with: &number, blockBuffer: data, offsetIntoDestination: 0, dataLength: 4)
            var timing = CMSampleTimingInfo(
                duration: CMTimeMultiply(frameDuration, multiplier: 90), presentationTimeStamp: .zero,
                decodeTimeStamp: .invalid
            )
            var size = 4
            var sample: CMSampleBuffer?
            try #require(CMSampleBufferCreate(
                allocator: nil, dataBuffer: data, dataReady: true, makeDataReadyCallback: nil, refcon: nil,
                formatDescription: timecodeFormat, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
            ) == noErr)
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            #expect(input.append(try #require(sample)))
            input.markAsFinished()
        }
        let frames = 90
        for index in 0 ..< frames {
            while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try #require(buffer)
            #expect(adaptor.append(pixels, withPresentationTime: CMTimeMultiply(frameDuration, multiplier: Int32(index))))
        }
        video.markAsFinished()
        writer.endSession(atSourceTime: CMTimeMultiply(frameDuration, multiplier: Int32(frames)))
        await writer.finishWriting()
        #expect(writer.status == .completed, "\(String(describing: writer.error))")
        return url
    }

    /// A short Broadcast WAV, at 48 kHz, with a time reference of `samples`.
    private func makeBroadcastWAV(named name: String, samples: UInt64) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "EDLSourceTimecode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func le<Value: FixedWidthInteger>(_ value: Value) -> Data {
            withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        var format = le(UInt16(1)) + le(UInt16(1)) + le(UInt32(48000)) + le(UInt32(96000))
        format += le(UInt16(2)) + le(UInt16(16))
        var bext = Data(count: 338) + le(UInt32(samples & 0xFFFF_FFFF)) + le(UInt32(samples >> 32))
        bext += Data(count: 602 - bext.count)
        let sound = Data(count: 48000 * 2)
        var body = Data("WAVE".utf8)
        for (id, chunk) in [("fmt ", format), ("bext", bext), ("data", sound)] {
            body += Data(id.utf8) + le(UInt32(chunk.count)) + chunk
        }
        let url = folder.appending(path: name)
        try (Data("RIFF".utf8) + le(UInt32(body.count)) + body).write(to: url)
        return url
    }

    @Test func readsTheStartTimecode() async throws {
        let stamped = try await makeMovie(named: "Stamped.mov", startFrame: 108_000)
        let timecode = try #require(await MediaTimecode.start(of: stamped))
        #expect(timecode.time == seconds(3600))
        #expect(timecode.frames == MediaTimecode.Frames(number: 108_000, frameDuration: seconds(1, 30), isDropFrame: false))
        #expect(try await MediaProbe.probe(stamped).metadata.timecode == timecode)
        let plain = try await makeMovie(named: "Plain.mov", startFrame: nil)
        #expect(await MediaTimecode.start(of: plain) == nil)
    }

    @Test func readsABroadcastWAVsTimeReference() async throws {
        // 14:23:10 into the day.
        let wav = try makeBroadcastWAV(named: "Take 4.wav", samples: 51790 * 48000)
        let timecode = try #require(await MediaTimecode.start(of: wav))
        #expect(timecode.time == seconds(51790))
        #expect(timecode.frames == nil)
        #expect(try await MediaProbe.probe(wav).metadata.timecode?.time == seconds(51790))
    }

    @Test func movesClipsOntoFoundMediaByItsTimecode() async throws {
        let movie = try await makeMovie(named: "A001C003.mov", startFrame: 108_000)
        let edl = """
        TITLE: Camera
        FCM: NON-DROP FRAME
        001  A001C003 V     C        01:00:01:00 01:00:02:15 01:00:00:00 01:00:01:15
        * FROM CLIP NAME: A001C003.mov
        """
        let imported = try ProjectInterchange.read(Data(edl.utf8), baseURL: movie.deletingLastPathComponent())
        // Not sized from the timecode before it's found, and marked as in it.
        #expect(imported.project.media.first?.metadata.duration == .zero)
        #expect(imported.project.media.first?.sourceTimecode != nil)
        #expect(imported.project.tracks.first?.clips.first?.sourceRange.start == seconds(3601))

        let gathered = await ProjectInterchange.gatherMedia(
            for: imported, into: PackageMediaStore(), searchFolders: [movie.deletingLastPathComponent()]
        )
        #expect(gathered.issues(.missingMedia).isEmpty)
        #expect(gathered.report.items.allSatisfy { $0.issue != .beforeMediaStart })
        let clip = try #require(gathered.project.tracks.first?.clips.first)
        #expect(clip.sourceRange == CMTimeRange(start: seconds(1), duration: seconds(45, 30)))
        #expect(gathered.project.media.first?.metadata.duration == seconds(3))
        #expect(gathered.project.media.first?.sourceTimecode == nil)
    }

    @Test func reportsClipsThatStartBeforeTheirMedia() async throws {
        let movie = try await makeMovie(named: "A001C004.mov", startFrame: 108_000)
        let edl = """
        TITLE: Handles
        FCM: NON-DROP FRAME
        001  A001C004 V     C        00:59:59:00 01:00:00:00 01:00:00:00 01:00:01:00
        * FROM CLIP NAME: A001C004.mov
        002  A001C004 V     C        01:00:01:00 01:00:02:00 01:00:01:00 01:00:02:00
        * FROM CLIP NAME: A001C004.mov
        """
        let imported = try ProjectInterchange.read(Data(edl.utf8), baseURL: movie.deletingLastPathComponent())
        let gathered = await ProjectInterchange.gatherMedia(
            for: imported, into: PackageMediaStore(), searchFolders: [movie.deletingLastPathComponent()]
        )
        #expect(gathered.project.tracks.first?.clips.map(\.sourceRange.start) == [.zero, seconds(1)])
        let early = gathered.report.items.filter { $0.issue == .beforeMediaStart }
        #expect(early.map(\.time) == [.zero])
    }

    @Test func leavesMediaWithNoTimecodeAsTheListHasIt() async throws {
        let movie = try await makeMovie(named: "Phone.mov", startFrame: nil)
        let edl = """
        TITLE: Phone
        FCM: NON-DROP FRAME
        001  AX       V     C        00:00:01:00 00:00:02:00 01:00:00:00 01:00:01:00
        * FROM CLIP NAME: Phone.mov
        """
        let imported = try ProjectInterchange.read(Data(edl.utf8), baseURL: movie.deletingLastPathComponent())
        let gathered = await ProjectInterchange.gatherMedia(
            for: imported, into: PackageMediaStore(), searchFolders: [movie.deletingLastPathComponent()]
        )
        #expect(gathered.project.tracks.first?.clips.first?.sourceRange.start == seconds(1))
    }

    @Test func leavesAListCountedFromEachFilesStartAsItIs() async throws {
        let movie = try await makeMovie(named: "B001C001.mov", startFrame: 108_000)
        let edl = """
        TITLE: From zero
        FCM: NON-DROP FRAME
        001  AX       V     C        00:00:01:00 00:00:02:00 01:00:00:00 01:00:01:00
        * FROM CLIP NAME: B001C001.mov
        """
        let imported = try ProjectInterchange.read(Data(edl.utf8), baseURL: movie.deletingLastPathComponent())
        let gathered = await ProjectInterchange.gatherMedia(
            for: imported, into: PackageMediaStore(), searchFolders: [movie.deletingLastPathComponent()]
        )
        #expect(gathered.project.tracks.first?.clips.first?.sourceRange.start == seconds(1))
        #expect(gathered.report.items.allSatisfy { $0.issue != .beforeMediaStart })

        // The same when the file is only found later.
        var project = imported.project
        let item = try #require(project.media.first)
        let counting = try #require(item.sourceTimecode)
        let start = MediaTimecode(time: seconds(3600), frames: .init(number: 108_000, frameDuration: seconds(1, 30), isDropFrame: false))
        #expect(project.moveSourceRanges(of: item.id, ontoFileStartingAt: counting.offset(toStartOf: start)).isEmpty)
        #expect(project.tracks.first?.clips.first?.sourceRange.start == seconds(1))
    }

    @Test func movesClipsInTimecodeOntoARelinkedFile() {
        let item = MediaItem(name: "A.mov", kind: .video, location: .package(path: "Media/A.mov"), metadata: MediaMetadata())
        // A file starting five seconds in, longer than the clips' timecode.
        let inTimecode = Clip(mediaID: item.id, sourceRange: CMTimeRange(start: seconds(60), duration: seconds(10)))
        var project = Project(media: [item], tracks: [Track(kind: .video, clips: [inTimecode])])
        let early = project.moveSourceRanges(of: item.id, ontoFileStartingAt: seconds(5))
        #expect(early.isEmpty)
        #expect(project.tracks[0].clips[0].sourceRange.start == seconds(55))
    }

    @Test func countsAFilesTimecodeAsTheListDoes() {
        // A drop frame list whose media turns out to be 25 fps, stamped 10:00:00:00.
        let counting = MediaItem.SourceTimecode(frameDuration: seconds(1001, 30000), isDropFrame: true)
        let start = MediaTimecode(time: seconds(36000), frames: .init(number: 900_000, frameDuration: seconds(1, 25), isDropFrame: false))
        let listed = EDLTimecode(hours: 10, minutes: 0, seconds: 0, frames: 0).frameCount(at: .ntsc30, dropFrame: true)
        #expect(counting.offset(toStartOf: start) == EDLRate.ntsc30.time(listed))
    }

    @Test func doesntHoldAStandInsLengthOrSizeAgainstARelinkedFile() {
        let counting = MediaItem.SourceTimecode(frameDuration: seconds(1, 30), isDropFrame: false)
        let item = MediaItem(
            name: "A.mov", kind: .video, location: .package(path: "Media/A.mov"),
            metadata: MediaMetadata(naturalSize: CGSize(width: 1920, height: 1080)), sourceTimecode: counting
        )
        var metadata = MediaMetadata(duration: seconds(3), naturalSize: CGSize(width: 3840, height: 2160))
        metadata.nominalFrameRate = 30
        #expect(MediaRelinker.differences(between: item, and: ProbedMedia(kind: .video, metadata: metadata)).isEmpty)
    }

    @Test func exportsSourcePointsInTheMediasTimecode() throws {
        var metadata = MediaMetadata(duration: seconds(20), naturalSize: CGSize(width: 64, height: 64), nominalFrameRate: 30)
        metadata.timecode = MediaTimecode(
            time: seconds(3600), frames: .init(number: 108_000, frameDuration: seconds(1, 30), isDropFrame: false)
        )
        let item = MediaItem(name: "A001C003.mov", kind: .video, location: .package(path: "Media/A001C003.mov"), metadata: metadata)
        var clip = Clip(mediaID: item.id, sourceRange: CMTimeRange(start: seconds(10), duration: seconds(2)))
        clip.isAudioDetached = true
        let project = Project(media: [item], tracks: [Track(kind: .video, clips: [clip])])
        let text = String(decoding: ProjectInterchange.edl(for: project, named: "Camera", mediaResolver: .none), as: UTF8.self)
        #expect(text.contains("001  AX       V     C        01:00:10:00 01:00:12:00 01:00:00:00 01:00:02:00"))

        // Read back with the media found, it lands where it was.
        var imported = try ProjectInterchange.read(Data(text.utf8), baseURL: nil)
        let read = try #require(imported.project.media.first)
        let counting = try #require(read.sourceTimecode)
        imported.project.moveSourceRanges(of: read.id, ontoFileStartingAt: counting.offset(toStartOf: try #require(metadata.timecode)))
        #expect(imported.project.tracks.first?.clips.first?.sourceRange.start == seconds(10))
    }
}
