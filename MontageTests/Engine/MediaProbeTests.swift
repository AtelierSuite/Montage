import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
@testable import MontageEngine
import Testing

struct MediaProbeTests {
    @Test(.enabled(if: Samples.isAvailable))
    func readsHEVCAt60FramesPerSecond() async throws {
        let media = try await MediaProbe.probe(Samples.url("IMG_3311.mp4"))
        #expect(media.kind == .video)
        #expect(media.metadata.naturalSize == CGSize(width: 1920, height: 1080))
        #expect(media.metadata.rotation == 0)
        #expect(media.metadata.nominalFrameRate == 60)
        #expect(!media.metadata.isVariableFrameRate)
        #expect(media.metadata.audioChannelCount == 2)
        #expect(media.metadata.audioSampleRate > 0)
        #expect(abs(media.metadata.duration.seconds - 11.25) < 0.01)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func takesAPhonesRoundedTimingAsItsStandardRate() async throws {
        // Timed in 600ths, its frames alternate between 20 and 21 units:
        // 29.97 fps as near as 600ths can hold it, averaging 29.975.
        let media = try await MediaProbe.probe(Samples.url("IMG_1805.MOV"))
        #expect(media.kind == .video)
        #expect(abs(media.metadata.nominalFrameRate - 30000.0 / 1001) < 0.0001)
        #expect(!media.metadata.isVariableFrameRate)
        #expect(media.metadata.hasAudio)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func readsPortraitFrames() async throws {
        let media = try await MediaProbe.probe(Samples.url("IMG_3312.mp4"))
        #expect(media.metadata.presentationSize == CGSize(width: 1080, height: 1920))
    }

    @Test(.enabled(if: Samples.isAvailable), arguments: ["IMG_1805.avi", "IMG_1813.avi"])
    func refusesAVI(_ name: String) async {
        await #expect(throws: MediaProbeError.unsupported(fileName: name)) {
            try await MediaProbe.probe(Samples.url(name))
        }
    }

    @Test(.enabled(if: Samples.isAvailable), arguments: ["IMG_2459.JPG", "IMG_2467.jpeg", "windows11-icon.png"])
    func readsImages(_ name: String) async throws {
        let media = try await MediaProbe.probe(Samples.url(name))
        #expect(media.kind == .image)
        #expect(media.metadata.naturalSize.width > 0 && media.metadata.naturalSize.height > 0)
        #expect(media.metadata.duration == .zero)
        #expect(!media.metadata.hasAudio)
    }

    @Test func refusesAFileThatIsntMedia() async throws {
        let url = URL.temporaryDirectory.appending(path: "\(UUID().uuidString).mov")
        try Data("not a movie".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: MediaProbeError.self) { try await MediaProbe.probe(url) }
    }

    @Test func readsRotationFromTheTransform() {
        #expect(MediaProbe.rotation(for: .identity) == 0)
        #expect(MediaProbe.rotation(for: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0)) == 90)
        #expect(MediaProbe.rotation(for: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 1920, ty: 1080)) == 180)
        #expect(MediaProbe.rotation(for: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 1920)) == 270)
        #expect(MediaProbe.rotation(for: .right) == 90)
        #expect(MediaProbe.rotation(for: .left) == 270)
    }

    @Test func tellsAVariableRateFromRounding() {
        func durations(_ values: [Int64], timescale: Int32 = 600) -> [CMTime] {
            values.map { CMTime(value: $0, timescale: timescale) }
        }
        let minimum = CMTime(value: 20, timescale: 600)
        #expect(!MediaProbe.isVariableFrameRate(frameDurations: durations([20, 20, 21, 20, 20, 21]), nominalFrameRate: 29.97, minFrameDuration: minimum))
        #expect(MediaProbe.isVariableFrameRate(frameDurations: durations([20, 40, 20, 33]), nominalFrameRate: 24, minFrameDuration: minimum))
        // Without timings, the shortest frame against the average.
        #expect(MediaProbe.isVariableFrameRate(frameDurations: [], nominalFrameRate: 24, minFrameDuration: CMTime(value: 1, timescale: 60)))
        #expect(!MediaProbe.isVariableFrameRate(frameDurations: [], nominalFrameRate: 30, minFrameDuration: CMTime(value: 1, timescale: 30)))
    }

    @Test func snapsNearbyRatesToStandardOnes() {
        #expect(MediaProbe.standardFrameRate(near: 59.95) == 60000.0 / 1001)
        #expect(MediaProbe.standardFrameRate(near: 25) == 25)
        #expect(MediaProbe.standardFrameRate(near: 17.3) == 17.3)
    }
}
