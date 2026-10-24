import AVFoundation
import CoreMedia
import Foundation

/// How loud a piece of media is over time, as the timeline draws it: the
/// loudest sample in each short stretch, across every channel.
///
/// Peaks are kept at a fixed `peaksPerSecond`, fine enough for the closest
/// zoom, and drawn at any other by `peaks(in:count:)`, which takes the
/// loudest of the peaks each drawn bar covers.
public struct WaveformPeaks: Equatable, Sendable {
    /// How many peaks there are for each second of the media.
    public var peaksPerSecond: Double
    /// Each from 0, silence, to 1, full scale.
    public var peaks: [Float]

    public init(peaksPerSecond: Double, peaks: [Float]) {
        self.peaksPerSecond = peaksPerSecond
        self.peaks = peaks
    }

    /// How long the peaks cover.
    public var duration: CMTime {
        guard peaksPerSecond > 0 else { return .zero }
        return CMTime(seconds: Double(peaks.count) / peaksPerSecond, preferredTimescale: 600)
    }

    /// `count` peaks spread evenly over `range` of the media, such as one for
    /// each bar of a clip on the timeline, each the loudest of the peaks it
    /// covers. Time beyond the media is silent.
    public func peaks(in range: CMTimeRange, count: Int) -> [Float] {
        guard count > 0, peaksPerSecond > 0, range.duration.isNumeric, range.duration > .zero else {
            return Array(repeating: 0, count: max(count, 0))
        }
        let start = range.start.seconds * peaksPerSecond
        let step = range.duration.seconds * peaksPerSecond / Double(count)
        return (0..<count).map { bar in
            let from = Int((start + Double(bar) * step).rounded(.down))
            // Each bar covers at least one peak, so zooming in past the
            // peaks' own resolution repeats them rather than leaving gaps.
            let to = max(Int((start + Double(bar + 1) * step).rounded(.down)), from + 1)
            let lower = max(from, 0), upper = min(to, peaks.count)
            guard lower < upper else { return 0 }
            return peaks[lower..<upper].max() ?? 0
        }
    }
}

/// Reads the sound of media and boils it down to `WaveformPeaks`.
public enum WaveformGenerator {
    /// Fine enough for a timeline zoomed in to a few frames a point.
    public static let defaultPeaksPerSecond: Double = 100

    public enum Failure: Error {
        /// The media has no sound.
        case noAudio
        /// The sound couldn't be read.
        case unreadable
    }

    /// The peaks of the media's main audio track: the first that's on, as
    /// phones add extra tracks, such as spatial audio, that are turned off.
    @concurrent
    public static func peaks(of url: URL, peaksPerSecond: Double = defaultPeaksPerSecond) async throws -> WaveformPeaks {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var main = tracks.first
        for track in tracks where try await track.load(.isEnabled) {
            main = track
            break
        }
        guard let track = main else { throw Failure.noAudio }
        // Reading blocks until the reader has decoded the next buffer, for
        // as long as the media runs; on a queue of its own, so a timeline
        // reading many waveforms at once doesn't hold every shared thread.
        return try await withTaskExecutorPreference(DispatchQueue(label: "Montage.Waveform")) {
            try read(track, of: asset, peaksPerSecond: peaksPerSecond)
        }
    }

    private static func read(_ track: AVAssetTrack, of asset: AVAsset, peaksPerSecond: Double) throws -> WaveformPeaks {
        let reader = try AVAssetReader(asset: asset)
        // Interleaved 32-bit floats, at the track's own rate and channels.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure.unreadable }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? Failure.unreadable }

        var accumulator = PeakAccumulator(peaksPerSecond: peaksPerSecond)
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            accumulator.add(buffer)
        }
        guard reader.status == .completed else {
            reader.cancelReading()
            throw reader.error ?? Failure.unreadable
        }
        return WaveformPeaks(peaksPerSecond: peaksPerSecond, peaks: accumulator.finish())
    }
}

/// Collects the loudest sample of every stretch as buffers of samples come.
private struct PeakAccumulator {
    let peaksPerSecond: Double
    private var peaks: [Float] = []
    private var current: Float = 0
    /// Frames (samples across all channels) into the current stretch.
    private var framesInCurrent = 0
    private var framesPerPeak = 0

    init(peaksPerSecond: Double) {
        self.peaksPerSecond = peaksPerSecond
    }

    mutating func add(_ buffer: CMSampleBuffer) {
        guard let format = buffer.formatDescription,
              let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              let block = buffer.dataBuffer else { return }
        let channels = max(Int(description.mChannelsPerFrame), 1)
        if framesPerPeak == 0 {
            framesPerPeak = max(Int((description.mSampleRate / peaksPerSecond).rounded()), 1)
        }
        let frames = CMSampleBufferGetNumSamples(buffer)
        let length = CMBlockBufferGetDataLength(block)
        guard frames > 0, length > 0 else { return }
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes { bytes in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: bytes.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return }
        let count = min(frames * channels, samples.count)
        var index = 0
        while index < count {
            let frameEnd = min(index + channels, count)
            for sample in index..<frameEnd {
                let level = abs(samples[sample])
                if level > current { current = level }
            }
            index = frameEnd
            framesInCurrent += 1
            if framesInCurrent == framesPerPeak {
                peaks.append(min(current, 1))
                current = 0
                framesInCurrent = 0
            }
        }
    }

    mutating func finish() -> [Float] {
        if framesInCurrent > 0 { peaks.append(min(current, 1)) }
        return peaks
    }
}
