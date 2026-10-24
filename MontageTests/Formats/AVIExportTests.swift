import CoreMedia
import Foundation
import MontageEngine
@testable import MontageFormats
import Testing

/// The exporter's AVI pipeline writing through `AVIWriter`, end to end.
@Suite(.enabled(if: Samples.isAvailable, "Needs the sample media"))
struct AVIExportTests {
    private func export(codec: ExportVideoCodec) async throws {
        let range = CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: 2, timescale: 1))
        let source = try await RenderSource.file(at: Samples.url("IMG_3311.mp4"), timeRange: range)
        let settings = ExportSettings(format: .avi, codec: codec, resolution: .hd720, frameRate: .fps(30), quality: .medium)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Export.avi")

        let exporter = Exporter(aviSinkFactory: AVIWriter.encodedFrameSinkFactory)
        #expect(exporter.supports(.avi))
        try await exporter.export(source, settings: settings, to: url)

        let size = settings.resolution.size(for: source.renderSize)
        let video = AVIWriter.VideoSettings(
            codec: codec == .h264 ? .h264 : .motionJPEG, width: Int(size.width), height: Int(size.height),
            frameRate: AVIWriter.FrameRate(30)
        )
        let audio = AVIWriter.AudioSettings(sampleRate: 48_000, channels: 2)
        let layout = try AVILayout(RIFFFile(url: url), video: video, audio: audio)
        #expect(abs(layout.videoFrames - 60) <= 1)
        #expect(abs(layout.audioSamples - 96_000) <= 4096)

        guard FFmpeg.isAvailable else { return }
        let (probe, errors) = try FFmpeg.probe(url)
        #expect(errors.isEmpty, "\(errors)")
        #expect(probe.formatName == "avi")
        #expect(probe.stream("video")?["codec_name"] as? String == (codec == .h264 ? "h264" : "mjpeg"))
        #expect(probe.stream("video")?["width"] as? Int == video.width)
        #expect(probe.stream("audio")?["codec_name"] as? String == "pcm_s16le")
        #expect(abs(probe.duration - 2) < 0.1)
    }

    @Test func exportsMotionJPEGAVI() async throws {
        try await export(codec: .motionJPEG)
    }

    @Test func exportsH264AVI() async throws {
        try await export(codec: .h264)
    }
}
