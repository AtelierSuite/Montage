import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct WaveformTests {
    @Test(.enabled(if: Samples.isAvailable))
    func readsPeaksForTheWholeOfAVideosSound() async throws {
        let url = Samples.url("IMG_3311.mp4")
        let probed = try await MediaProbe.probe(url)
        let waveform = try await WaveformGenerator.peaks(of: url)
        #expect(waveform.peaksPerSecond == WaveformGenerator.defaultPeaksPerSecond)
        // A peak every hundredth of a second, for as long as the sound runs.
        #expect(abs(waveform.duration.seconds - probed.metadata.duration.seconds) < 0.2)
        #expect(waveform.peaks.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect(waveform.peaks.contains { $0 > 0.01 })
    }

    @Test(.enabled(if: Samples.isAvailable))
    func hasNoPeaksWithoutSound() async throws {
        await #expect(throws: (any Error).self) {
            try await WaveformGenerator.peaks(of: Samples.url("IMG_2459.JPG"))
        }
    }

    @Test func drawsTheLoudestPeakEachBarCovers() {
        let waveform = WaveformPeaks(peaksPerSecond: 4, peaks: [0.1, 0.5, 0.2, 0.3, 0.9, 0, 0, 0.4])
        let whole = CMTimeRange(start: .zero, duration: CMTime(value: 2, timescale: 1))
        #expect(waveform.peaks(in: whole, count: 2) == [0.5, 0.9])
        #expect(waveform.peaks(in: whole, count: 4) == [0.5, 0.3, 0.9, 0.4])
        // Zoomed past the peaks' own resolution, each is repeated.
        let first = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 2))
        #expect(waveform.peaks(in: first, count: 4) == [0.1, 0.1, 0.5, 0.5])
        // Past the end of the media, it's silent.
        let beyond = CMTimeRange(start: CMTime(value: 3, timescale: 2), duration: CMTime(value: 1, timescale: 1))
        #expect(waveform.peaks(in: beyond, count: 2) == [0.4, 0])
    }

    @Test func survivesBeingWrittenAndReadBack() throws {
        let waveform = WaveformPeaks(peaksPerSecond: 100, peaks: [0, 0.5, 1, 0.25])
        let read = try #require(WaveformPeaks(encoded: waveform.encoded()))
        #expect(read.peaksPerSecond == 100)
        #expect(zip(read.peaks, waveform.peaks).allSatisfy { abs($0 - $1) < 0.005 })
        #expect(WaveformPeaks(encoded: Data("nonsense".utf8)) == nil)
    }

    @Test(.enabled(if: Samples.isAvailable))
    func keepsAWaveformOnceRead() async throws {
        let item = MediaItem(name: "IMG_3311.mp4", kind: .video, location: .package(path: "Media/IMG_3311.mp4"),
                             metadata: MediaMetadata())
        let cache = WaveformCache()
        let first = try #require(await cache.waveform(for: item, at: Samples.url("IMG_3311.mp4")))
        let second = await cache.waveform(for: item, at: URL(fileURLWithPath: "/nonexistent.mp4"))
        #expect(second == first)
        await cache.removeWaveform(for: item.id)
        #expect(await cache.waveform(for: item, at: URL(fileURLWithPath: "/nonexistent.mp4")) == nil)
    }
}
