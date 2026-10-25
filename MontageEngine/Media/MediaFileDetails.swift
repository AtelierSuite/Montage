import AVFoundation
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the library says about a media file beyond its metadata: how it's
/// encoded and how big it is. Read from the file when it's wanted, so it's
/// there for media imported before it was asked for, and right after a
/// relink.
public struct MediaFileDetails: Equatable, Sendable {
    /// The video's codec, or an image's format, such as "HEVC" or "JPEG".
    public var videoCodec: String?
    /// The main audio track's codec, such as "AAC".
    public var audioCodec: String?
    /// The file's size in bytes.
    public var byteCount: Int64?

    public init(videoCodec: String? = nil, audioCodec: String? = nil, byteCount: Int64? = nil) {
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.byteCount = byteCount
    }

    /// The codecs, video first, joined for showing: "H.264, AAC".
    public var codecs: String? {
        let codecs = [videoCodec, audioCodec].compactMap { $0 }
        return codecs.isEmpty ? nil : codecs.joined(separator: ", ")
    }

    /// Reads the details of the file at `url`, holding media of `kind`.
    /// Whatever can't be read is left out.
    public static func read(at url: URL, kind: MediaItem.Kind) async -> MediaFileDetails {
        var details = MediaFileDetails()
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            details.byteCount = Int64(size)
        }
        if kind == .image {
            if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) {
                details.videoCodec = imageFormatName(for: type as String)
            }
            return details
        }
        let asset = AVURLAsset(url: url)
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let description = try? await track.load(.formatDescriptions).first {
            details.videoCodec = codecName(for: CMFormatDescriptionGetMediaSubType(description))
        }
        if let track = try? await asset.loadTracks(withMediaType: .audio).first,
           let description = try? await track.load(.formatDescriptions).first {
            details.audioCodec = codecName(for: CMFormatDescriptionGetMediaSubType(description))
        }
        return details
    }

    /// The common name of a codec, from its four-character code; the code
    /// itself for one without.
    public static func codecName(for code: FourCharCode) -> String {
        if let name = codecNames[code] { return name }
        let characters = [24, 16, 8, 0].map { Character(Unicode.Scalar(UInt8((code >> $0) & 0xFF))) }
        return String(characters).trimmingCharacters(in: .whitespaces)
    }

    private static let codecNames: [FourCharCode: String] = [
        kCMVideoCodecType_H264: "H.264",
        kCMVideoCodecType_HEVC: "HEVC",
        kCMVideoCodecType_HEVCWithAlpha: "HEVC",
        kCMVideoCodecType_AppleProRes422Proxy: "ProRes 422 Proxy",
        kCMVideoCodecType_AppleProRes422LT: "ProRes 422 LT",
        kCMVideoCodecType_AppleProRes422: "ProRes 422",
        kCMVideoCodecType_AppleProRes422HQ: "ProRes 422 HQ",
        kCMVideoCodecType_AppleProRes4444: "ProRes 4444",
        kCMVideoCodecType_AppleProRes4444XQ: "ProRes 4444 XQ",
        kCMVideoCodecType_AppleProResRAW: "ProRes RAW",
        kCMVideoCodecType_AppleProResRAWHQ: "ProRes RAW HQ",
        kCMVideoCodecType_MPEG4Video: "MPEG-4",
        kCMVideoCodecType_MPEG2Video: "MPEG-2",
        kCMVideoCodecType_JPEG: "Motion JPEG",
        kCMVideoCodecType_VP9: "VP9",
        kCMVideoCodecType_AV1: "AV1",
        kAudioFormatMPEG4AAC: "AAC",
        kAudioFormatMPEG4AAC_HE: "HE-AAC",
        kAudioFormatMPEG4AAC_HE_V2: "HE-AAC v2",
        kAudioFormatLinearPCM: "PCM",
        kAudioFormatAppleLossless: "ALAC",
        kAudioFormatMPEGLayer3: "MP3",
        kAudioFormatAC3: "AC-3",
        kAudioFormatEnhancedAC3: "E-AC-3",
        kAudioFormatFLAC: "FLAC",
        kAudioFormatOpus: "Opus",
    ]

    /// The name of an image's format, from its type identifier: "JPEG",
    /// "HEIC", "PNG".
    public static func imageFormatName(for identifier: String) -> String {
        guard let type = UTType(identifier) else { return identifier }
        if type.conforms(to: .jpeg) { return "JPEG" }
        if type.conforms(to: .heic) { return "HEIC" }
        if type.conforms(to: .heif) { return "HEIF" }
        if type.conforms(to: .png) { return "PNG" }
        if type.conforms(to: .tiff) { return "TIFF" }
        return type.preferredFilenameExtension?.uppercased() ?? identifier
    }
}

extension MediaMetadata {
    /// The frame rate as shown: to two places, without trailing zeros,
    /// such as "29.97", "25" or "23.98". Nil without video.
    public var formattedFrameRate: String? {
        guard nominalFrameRate > 0, nominalFrameRate.isFinite else { return nil }
        return nominalFrameRate.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    /// The upright size of the picture, as "1920×1080". Nil without one.
    public var formattedResolution: String? {
        let size = presentationSize
        guard size.width > 0, size.height > 0 else { return nil }
        return "\(Int(size.width.rounded()))×\(Int(size.height.rounded()))"
    }
}
