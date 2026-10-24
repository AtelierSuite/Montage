import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What a file holds, read when it's imported.
public struct ProbedMedia: Equatable, Sendable {
    public var kind: MediaItem.Kind
    public var metadata: MediaMetadata

    public init(kind: MediaItem.Kind, metadata: MediaMetadata) {
        self.kind = kind
        self.metadata = metadata
    }
}

/// Reads a file's kind and metadata, refusing what Montage can't play.
public enum MediaProbe {
    /// Frame rates video is made at. A rate read from a file that's within a
    /// hair of one of these is taken to be it: a phone's 29.97 fps video timed
    /// in 600ths of a second averages 29.975.
    static let standardFrameRates: [Double] = [
        24000.0 / 1001, 24, 25, 30000.0 / 1001, 30, 48, 50, 60000.0 / 1001, 60, 100, 120000.0 / 1001, 120, 240,
    ]

    /// How many frames are looked at to tell whether they come evenly.
    static let frameTimingSampleCount = 600

    public static func probe(_ url: URL) async throws -> ProbedMedia {
        if isImage(url) {
            return try probeImage(url)
        }
        return try await probeMovie(url)
    }

    // MARK: - Images

    private static func isImage(_ url: URL) -> Bool {
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) { return true }
        return false
    }

    private static func probeImage(_ url: URL) throws -> ProbedMedia {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
            throw MediaProbeError.unsupported(fileName: url.lastPathComponent)
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? UInt32)
            .flatMap(CGImagePropertyOrientation.init(rawValue:)) ?? .up
        return ProbedMedia(kind: .image, metadata: MediaMetadata(
            naturalSize: CGSize(width: width, height: height), rotation: rotation(for: orientation)
        ))
    }

    /// The clockwise turn that shows an image upright, for its EXIF
    /// orientation. A mirrored orientation is taken as its turn alone.
    static func rotation(for orientation: CGImagePropertyOrientation) -> Int {
        switch orientation {
        case .up, .upMirrored: 0
        case .down, .downMirrored: 180
        case .right, .rightMirrored: 90
        case .left, .leftMirrored: 270
        }
    }

    // MARK: - Movies and audio

    private static func probeMovie(_ url: URL) async throws -> ProbedMedia {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let duration: CMTime
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            let (loadedDuration, isPlayable, hasProtectedContent) = try await asset.load(
                .duration, .isPlayable, .hasProtectedContent
            )
            guard isPlayable, !hasProtectedContent, loadedDuration.isNumeric, loadedDuration > .zero else {
                throw MediaProbeError.unsupported(fileName: url.lastPathComponent)
            }
            duration = loadedDuration
            videoTracks = try await asset.loadTracks(withMediaType: .video)
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch let error as MediaProbeError {
            throw error
        } catch {
            // AVFoundation can't open it at all: an AVI, say, or a damaged file.
            throw MediaProbeError.unsupported(fileName: url.lastPathComponent)
        }

        var metadata = MediaMetadata(duration: duration)
        if let video = videoTracks.first {
            try await readVideo(video, into: &metadata)
        }
        if let audio = audioTracks.first {
            try await readAudio(audio, into: &metadata)
        }
        if metadata.hasVideo {
            return ProbedMedia(kind: .video, metadata: metadata)
        } else if metadata.hasAudio {
            return ProbedMedia(kind: .audio, metadata: metadata)
        }
        throw MediaProbeError.unsupported(fileName: url.lastPathComponent)
    }

    private static func readVideo(_ track: AVAssetTrack, into metadata: inout MediaMetadata) async throws {
        let (naturalSize, transform, nominalFrameRate, minFrameDuration) = try await track.load(
            .naturalSize, .preferredTransform, .nominalFrameRate, .minFrameDuration
        )
        metadata.naturalSize = CGSize(width: abs(naturalSize.width), height: abs(naturalSize.height))
        metadata.rotation = rotation(for: transform)

        let durations = await frameDurations(of: track)
        metadata.isVariableFrameRate = isVariableFrameRate(
            frameDurations: durations, nominalFrameRate: Double(nominalFrameRate), minFrameDuration: minFrameDuration
        )
        metadata.nominalFrameRate = metadata.isVariableFrameRate
            ? Double(nominalFrameRate) : standardFrameRate(near: Double(nominalFrameRate))
    }

    private static func readAudio(_ track: AVAssetTrack, into metadata: inout MediaMetadata) async throws {
        let descriptions = try await track.load(.formatDescriptions)
        guard let description = descriptions.first,
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else { return }
        metadata.audioChannelCount = Int(format.mChannelsPerFrame)
        metadata.audioSampleRate = format.mSampleRate
    }

    /// The clockwise turn, to the nearest quarter, that a track's preferred
    /// transform makes. Phones record upright video as landscape frames with
    /// a quarter turn in the transform.
    static func rotation(for transform: CGAffineTransform) -> Int {
        let degrees = atan2(transform.b, transform.a) * 180 / .pi
        let quarters = Int((degrees / 90).rounded())
        return ((quarters % 4) + 4) % 4 * 90
    }

    static func standardFrameRate(near rate: Double) -> Double {
        guard rate > 0, let nearest = standardFrameRates.min(by: { abs($0 - rate) < abs($1 - rate) }) else { return rate }
        return abs(nearest - rate) / nearest < 0.002 ? nearest : rate
    }

    /// The durations of the first frames, in decode order, each in the
    /// track's own timescale. Empty where the track can't say.
    private static func frameDurations(of track: AVAssetTrack) async -> [CMTime] {
        guard (try? await track.load(.canProvideSampleCursors)) == true,
              let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() else { return [] }
        var durations: [CMTime] = []
        repeat {
            durations.append(cursor.currentSampleDuration)
        } while durations.count < frameTimingSampleCount && cursor.stepInDecodeOrder(byCount: 1) == 1
        return durations
    }

    /// Whether frames come at uneven intervals. A file timed in coarse units
    /// can't hold 29.97 fps exactly, so its frames alternate between two
    /// durations a unit apart; that's rounding, not a variable rate. Frames
    /// further apart than that are. Without frame timings, a shortest frame
    /// well under the average says the same.
    static func isVariableFrameRate(frameDurations: [CMTime], nominalFrameRate: Double, minFrameDuration: CMTime) -> Bool {
        let durations = frameDurations.filter { $0.isNumeric && $0 > .zero }
        if durations.count > 1, let shortest = durations.min(), let longest = durations.max() {
            // In the finer of the two timescales, so one unit means one unit.
            let timescale = max(shortest.timescale, longest.timescale)
            let spread = longest.convertScale(timescale, method: .roundHalfAwayFromZero).value
                - shortest.convertScale(timescale, method: .roundHalfAwayFromZero).value
            let unit = max(Int64(timescale / min(shortest.timescale, longest.timescale)), 1)
            return spread > unit
        }
        guard nominalFrameRate > 0, minFrameDuration.isNumeric, minFrameDuration > .zero else { return false }
        return minFrameDuration.seconds * nominalFrameRate < 0.9
    }
}

public enum MediaProbeError: LocalizedError, Equatable {
    /// Not a kind of file Montage can play: an AVI, a document, a damaged
    /// or protected file.
    case unsupported(fileName: String)

    public var errorDescription: String? {
        switch self {
        case .unsupported(let fileName):
            String(format: String(localized: "MediaProbe.Error.Unsupported", bundle: #bundle), fileName)
        }
    }

    public var recoverySuggestion: String? {
        String(localized: "MediaProbe.Error.Unsupported.Suggestion", bundle: #bundle)
    }
}
