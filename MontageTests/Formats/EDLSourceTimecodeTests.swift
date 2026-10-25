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

    @Test func readsTheStartTimecode() async throws {
        let stamped = try await makeMovie(named: "Stamped.mov", startFrame: 108_000)
        #expect(await MediaTimecode.start(of: stamped) == seconds(3600))
        let plain = try await makeMovie(named: "Plain.mov", startFrame: nil)
        #expect(await MediaTimecode.start(of: plain) == nil)
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
        // Not sized from the timecode before it's found.
        #expect(imported.project.media.first?.metadata.duration == .zero)
        #expect(imported.project.tracks.first?.clips.first?.sourceRange.start == seconds(3601))

        let gathered = await ProjectInterchange.gatherMedia(
            for: imported, into: PackageMediaStore(), searchFolders: [movie.deletingLastPathComponent()]
        )
        #expect(gathered.issues(.missingMedia).isEmpty)
        let clip = try #require(gathered.project.tracks.first?.clips.first)
        #expect(clip.sourceRange == CMTimeRange(start: seconds(1), duration: seconds(45, 30)))
        #expect(gathered.project.media.first?.metadata.duration == seconds(3))
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

    @Test func alignsClipsOnRelinkOnlyWhenTheyAreInTheFilesTimecode() {
        let item = MediaItem(name: "A.mov", kind: .video, location: .package(path: "Media/A.mov"), metadata: MediaMetadata())
        let inTimecode = Clip(mediaID: item.id, sourceRange: CMTimeRange(start: seconds(3601), duration: seconds(1)))
        var project = Project(media: [item], tracks: [Track(kind: .video, clips: [inTimecode])])
        let moved = project.alignSourceRanges(of: item.id, toTimecodeStart: seconds(3600), duration: seconds(3))
        #expect(moved)
        #expect(project.tracks[0].clips[0].sourceRange.start == seconds(1))
        // Already on the file: left alone.
        let movedAgain = project.alignSourceRanges(of: item.id, toTimecodeStart: seconds(3600), duration: seconds(3))
        #expect(!movedAgain)
        #expect(project.tracks[0].clips[0].sourceRange.start == seconds(1))
    }

    @Test func doesntHoldAnUnknownLengthAgainstARelinkedFile() {
        let item = MediaItem(name: "A.mov", kind: .video, location: .package(path: "Media/A.mov"), metadata: MediaMetadata())
        var metadata = MediaMetadata(duration: seconds(3))
        metadata.nominalFrameRate = 30
        let differences = MediaRelinker.differences(between: item, and: ProbedMedia(kind: .video, metadata: metadata))
        let durationDiffers = differences.contains { difference in
            if case .duration = difference { true } else { false }
        }
        #expect(!durationDiffers)
    }
}
