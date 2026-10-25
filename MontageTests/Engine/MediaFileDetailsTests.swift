import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct MediaFileDetailsTests {
    @Test func namesCodecs() {
        #expect(MediaFileDetails.codecName(for: kCMVideoCodecType_H264) == "H.264")
        #expect(MediaFileDetails.codecName(for: kCMVideoCodecType_HEVC) == "HEVC")
        #expect(MediaFileDetails.codecName(for: kCMVideoCodecType_AppleProRes422HQ) == "ProRes 422 HQ")
        #expect(MediaFileDetails.codecName(for: kAudioFormatMPEG4AAC) == "AAC")
        // One without a name is shown by its code.
        #expect(MediaFileDetails.codecName(for: 0x7878_7878) == "xxxx")

        #expect(MediaFileDetails.imageFormatName(for: "public.jpeg") == "JPEG")
        #expect(MediaFileDetails.imageFormatName(for: "public.heic") == "HEIC")
        #expect(MediaFileDetails.imageFormatName(for: "public.png") == "PNG")
        #expect(MediaFileDetails(videoCodec: "HEVC", audioCodec: "AAC").codecs == "HEVC, AAC")
        #expect(MediaFileDetails(audioCodec: "AAC").codecs == "AAC")
        #expect(MediaFileDetails().codecs == nil)
    }

    @Test func formatsFrameRatesAndSizes() {
        #expect(MediaMetadata(nominalFrameRate: 30000.0 / 1001).formattedFrameRate == "29.97")
        #expect(MediaMetadata(nominalFrameRate: 24000.0 / 1001).formattedFrameRate == "23.98")
        #expect(MediaMetadata(nominalFrameRate: 25).formattedFrameRate == "25")
        #expect(MediaMetadata().formattedFrameRate == nil)

        #expect(MediaMetadata(naturalSize: CGSize(width: 1920, height: 1080)).formattedResolution == "1920×1080")
        // Upright, for portrait video stored on its side.
        #expect(MediaMetadata(naturalSize: CGSize(width: 1920, height: 1080), rotation: 90).formattedResolution == "1080×1920")
        #expect(MediaMetadata().formattedResolution == nil)
    }

    @Test(.enabled(if: Samples.isAvailable)) func readsDetailsFromFiles() async throws {
        let movie = await MediaFileDetails.read(at: Samples.url("IMG_1805.MOV"), kind: .video)
        #expect(movie.videoCodec != nil)
        #expect(movie.audioCodec != nil)
        #expect((movie.byteCount ?? 0) > 0)

        let photo = await MediaFileDetails.read(at: Samples.url("IMG_2459.JPG"), kind: .image)
        #expect(photo.videoCodec == "JPEG")
        #expect(photo.audioCodec == nil)
        #expect((photo.byteCount ?? 0) > 0)

        let missing = await MediaFileDetails.read(at: Samples.url("Not There.mov"), kind: .video)
        #expect(missing == MediaFileDetails())
    }
}
