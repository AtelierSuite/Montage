@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@testable import MontageEngine
import Synchronization
import Testing

struct ExportSettingsTests {
    @Test func changingTheFormatKeepsTheCodecValid() {
        var settings = ExportSettings(format: .mp4, codec: .hevc)
        settings.format = .avi
        #expect(settings.codec == .motionJPEG)
        settings.codec = .h264
        settings.format = .mp4
        #expect(settings.codec == .h264)
        #expect(ExportSettings(format: .mp4, codec: .motionJPEG).codec == .h264)
    }

    @Test func resolutionsKeepTheShapeWithEvenSides() {
        let landscape = CGSize(width: 1920, height: 1080)
        #expect(ExportResolution.hd720.size(for: landscape) == CGSize(width: 1280, height: 720))
        #expect(ExportResolution.project.size(for: CGSize(width: 1081, height: 607)) == CGSize(width: 1082, height: 608))
        let portrait = CGSize(width: 1080, height: 1920)
        #expect(ExportResolution.hd720.size(for: portrait) == CGSize(width: 720, height: 1280))
        #expect(ExportResolution.options(for: landscape) == [.project, .hd720])
        #expect(ExportResolution.options(for: CGSize(width: 3840, height: 2160)) == [.project, .hd1080, .hd720])
    }

    @Test func estimatesGrowWithSizeQualityAndDuration() {
        let size = CGSize(width: 1920, height: 1080)
        let rate = CMTime(value: 1, timescale: 30)
        let minute = CMTime(value: 60, timescale: 1)
        let high = ExportSettings(format: .mp4, codec: .h264, quality: .high)
        let estimate = high.estimatedFileSize(duration: minute, renderSize: size, frameDuration: rate)
        // About 8 Mbit/s of 1080p30 H.264 and AAC: some 60 MB a minute.
        #expect(estimate > 40_000_000 && estimate < 90_000_000)
        var low = high
        low.quality = .low
        #expect(low.estimatedFileSize(duration: minute, renderSize: size, frameDuration: rate) < estimate)
        var hevc = high
        hevc.codec = .hevc
        #expect(hevc.estimatedFileSize(duration: minute, renderSize: size, frameDuration: rate) < estimate)
        var small = high
        small.resolution = .hd720
        #expect(small.estimatedFileSize(duration: minute, renderSize: size, frameDuration: rate) < estimate)
        #expect(high.estimatedFileSize(duration: .zero, renderSize: size, frameDuration: rate) == 0)
    }
}

@Suite(.enabled(if: Samples.isAvailable, "Needs the sample media"))
struct ExporterTests {
    private func temporaryURL(_ ext: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MontageExportTests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString).\(ext)")
    }

    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    private func exportMP4(_ sample: String, codec: ExportVideoCodec, expectedSubtype: FourCharCode) async throws {
        let source = try await RenderSource.file(at: Samples.url(sample), timeRange: range(1, 2))
        let settings = ExportSettings(format: .mp4, codec: codec, resolution: .hd720, frameRate: .fps(30), quality: .medium)
        let url = try temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let lastProgress = Mutex(0.0)
        try await Exporter().export(source, settings: settings, to: url) { value in lastProgress.withLock { $0 = value } }
        #expect(lastProgress.withLock { $0 } == 1)

        let output = AVURLAsset(url: url)
        let duration = try await output.load(.duration).seconds
        #expect(abs(duration - 2) < 0.1)

        let video = try #require(try await output.loadTracks(withMediaType: .video).first)
        let (naturalSize, formats, frameRate) = try await video.load(.naturalSize, .formatDescriptions, .nominalFrameRate)
        #expect(naturalSize == settings.resolution.size(for: source.renderSize))
        #expect(formats.first?.mediaSubType.rawValue == expectedSubtype)
        #expect(abs(frameRate - 30) < 1)

        let audio = try #require(try await output.loadTracks(withMediaType: .audio).first)
        let audioFormats = try await audio.load(.formatDescriptions)
        #expect(audioFormats.first?.mediaSubType.rawValue == kAudioFormatMPEG4AAC)

        // Two seconds of 720p at medium quality: well under the source's size.
        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        let estimate = settings.estimatedFileSize(duration: CMTime(value: 2, timescale: 1), renderSize: source.renderSize, frameDuration: source.frameDuration)
        #expect(size > 20_000)
        #expect(Double(size) < Double(estimate) * 2.5)
    }

    @Test func exportsH264MP4() async throws {
        try await exportMP4("IMG_3311.mp4", codec: .h264, expectedSubtype: kCMVideoCodecType_H264)
    }

    @Test func exportsHEVCMP4() async throws {
        try await exportMP4("IMG_3312.mp4", codec: .hevc, expectedSubtype: kCMVideoCodecType_HEVC)
    }

    @Test func exportsAProjectAsPreviewPlaysIt() async throws {
        // Two clips with a gap between them, landscape then portrait, in a
        // 1080p project: the built composition, exported as it plays.
        let landscape = MediaItem(name: "IMG_3311.mp4", kind: .video, location: .package(path: "IMG_3311.mp4"), metadata: MediaMetadata())
        let portrait = MediaItem(name: "IMG_3312.mp4", kind: .video, location: .package(path: "IMG_3312.mp4"), metadata: MediaMetadata())
        let first = Clip(mediaID: landscape.id, sourceRange: range(1, 1), timelineStart: .zero)
        let second = Clip(mediaID: portrait.id, sourceRange: range(1, 1), timelineStart: CMTime(value: 3, timescale: 2))
        let project = Project(media: [landscape, portrait], tracks: [Track(kind: .video, clips: [first, second])])
        let resolver = MediaResolver { item in
            guard case .package(let path) = item.location else { return nil }
            return Samples.url(path)
        }
        let built = try await CompositionBuilder(project: project, mediaResolver: resolver).build()
        let source = RenderSource(built)
        #expect(source.renderSize == CGSize(width: 1920, height: 1080))

        let url = try temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Exporter().export(source, settings: ExportSettings(resolution: .hd720, quality: .low), to: url)
        let output = AVURLAsset(url: url)
        #expect(abs(try await output.load(.duration).seconds - 2.5) < 0.1)
        let video = try #require(try await output.loadTracks(withMediaType: .video).first)
        #expect(try await video.load(.naturalSize) == CGSize(width: 1280, height: 720))
        #expect(!(try await output.loadTracks(withMediaType: .audio)).isEmpty)
    }

    @Test func cancellingRemovesThePartialFile() async throws {
        let source = try await RenderSource.file(at: Samples.url("IMG_3311.mp4"))
        let settings = ExportSettings(format: .mp4, codec: .h264, resolution: .project)
        let url = try temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let started = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            try await Exporter().export(source, settings: settings, to: url) { value in
                if value > 0.05 { started.continuation.yield() }
            }
        }
        for await _ in started.stream { break }
        #expect(FileManager.default.fileExists(atPath: url.path))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func aviNeedsAWriter() async throws {
        let source = try await RenderSource.file(at: Samples.url("IMG_3311.mp4"), timeRange: range(0, 0.5))
        let url = try temporaryURL("avi")
        #expect(!Exporter().supports(.avi))
        await #expect(throws: ExportError.self) {
            try await Exporter().export(source, settings: ExportSettings(format: .avi), to: url)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - AVI pipeline

    private func encodeAVI(
        codec: ExportVideoCodec, frameRate: Int, duration: Double, videoComposition: AVVideoComposition? = nil
    ) async throws -> (MockSink.Record, EncodedStreamDescription) {
        var source = try await RenderSource.file(at: Samples.url("IMG_3311.mp4"), timeRange: range(2, duration))
        source.videoComposition = videoComposition
        let sink = MockSink()
        let streams = Mutex<EncodedStreamDescription?>(nil)
        let exporter = Exporter { _, description in
            streams.withLock { $0 = description }
            return sink
        }
        let url = try temporaryURL("avi")
        let settings = ExportSettings(format: .avi, codec: codec, resolution: .hd720, frameRate: .fps(frameRate), quality: .medium)
        try await exporter.export(source, settings: settings, to: url)
        return (sink.record, try #require(streams.withLock { $0 }))
    }

    @Test func encodesMotionJPEGAndPCMForAVI() async throws {
        let (record, streams) = try await encodeAVI(codec: .motionJPEG, frameRate: 30, duration: 1)
        #expect(record.finished && !record.cancelled)
        #expect(streams.video?.codec == .motionJPEG)
        #expect(streams.video?.width == 1280 || streams.video?.height == 1280)
        #expect(abs(record.videoFrames - 30) <= 1)
        // Every Motion JPEG frame stands alone.
        #expect(record.keyframes == record.videoFrames)
        #expect(record.subtypes == [kCMVideoCodecType_JPEG])
        #expect(record.timesIncrease)
        // One second of 48 kHz stereo 16-bit PCM, give or take a buffer.
        let audio = try #require(streams.audio)
        #expect(audio.bytesPerFrame == 4)
        #expect(record.pcmBytes % audio.bytesPerFrame == 0)
        #expect(abs(record.pcmBytes - 192_000) <= 4096 * 4)
    }

    @Test func encodesH264WithKeyframesEveryTwoSecondsForAVI() async throws {
        // A video composition of the caller's own, at another frame rate.
        let asset = AVURLAsset(url: Samples.url("IMG_3311.mp4"))
        let composition = AVVideoComposition(configuration: try await AVVideoComposition.Configuration(for: asset))
        let (record, streams) = try await encodeAVI(codec: .h264, frameRate: 24, duration: 3, videoComposition: composition)
        #expect(record.finished)
        #expect(streams.video?.frameDuration == CMTime(value: 1, timescale: 24))
        #expect(abs(record.videoFrames - 72) <= 1)
        #expect(record.firstIsKeyframe)
        #expect(record.keyframes == 2)
        #expect(record.subtypes == [kCMVideoCodecType_H264])
        // No B-frames: decode order is presentation order.
        #expect(record.timesIncrease)
        #expect(abs(record.pcmBytes - 576_000) <= 4096 * 4)
    }

    @Test func cancellingTheAVIPipelineCancelsTheSink() async throws {
        let source = try await RenderSource.file(at: Samples.url("IMG_3311.mp4"))
        let sink = MockSink()
        let exporter = Exporter { _, _ in sink }
        let url = try temporaryURL("avi")
        let started = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            try await exporter.export(source, settings: ExportSettings(format: .avi, resolution: .hd720), to: url) { value in
                if value > 0.05 { started.continuation.yield() }
            }
        }
        for await _ in started.stream { break }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(sink.record.cancelled && !sink.record.finished)
    }
}

/// Counts what the AVI pipeline hands a container writer.
private final class MockSink: EncodedFrameSink, @unchecked Sendable {
    struct Record {
        var videoFrames = 0
        var keyframes = 0
        var firstIsKeyframe = false
        var subtypes: Set<FourCharCode> = []
        var timesIncrease = true
        var lastTime = CMTime.negativeInfinity
        var pcmBytes = 0
        var finished = false
        var cancelled = false
    }

    private let lock = NSLock()
    private var _record = Record()
    var record: Record { lock.withLock { _record } }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) throws {
        lock.withLock {
            if _record.videoFrames == 0 { _record.firstIsKeyframe = isKeyframe }
            _record.videoFrames += 1
            if isKeyframe { _record.keyframes += 1 }
            if let format = sampleBuffer.formatDescription { _record.subtypes.insert(format.mediaSubType.rawValue) }
            let time = sampleBuffer.presentationTimeStamp
            if time <= _record.lastTime || sampleBuffer.decodeTimeStamp.isNumeric && sampleBuffer.decodeTimeStamp != time {
                _record.timesIncrease = false
            }
            _record.lastTime = time
        }
    }

    func appendAudio(_ pcm: Data) throws {
        lock.withLock { _record.pcmBytes += pcm.count }
    }

    func finish() throws {
        lock.withLock { _record.finished = true }
    }

    func cancel() {
        lock.withLock { _record.cancelled = true }
    }
}
