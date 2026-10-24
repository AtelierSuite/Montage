import CoreGraphics
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

struct MediaRelinkerTests {
    static func item(_ name: String, _ kind: MediaItem.Kind = .video, _ metadata: MediaMetadata = MediaMetadata()) -> MediaItem {
        MediaItem(name: name, kind: kind, location: .package(path: "Media/\(name)"), metadata: metadata)
    }

    static let footage = MediaMetadata(
        duration: CMTime(value: 300, timescale: 30), naturalSize: CGSize(width: 1920, height: 1080), nominalFrameRate: 30
    )

    @Test func prefersTheSameNameThenTheSameNameWithAnotherExtension() {
        let files = ["/a/Other.mov", "/b/clip.mp4", "/a/CLIP.MOV", "/c/Clip.mov.txt"].map { URL(fileURLWithPath: $0) }
        let found = MediaRelinker.candidates(for: Self.item("Clip.mov"), among: files)
        #expect(found.map(\.path) == ["/a/CLIP.MOV", "/b/clip.mp4"])
    }

    @Test func confirmsByDurationFrameRateAndSize() {
        let item = Self.item("Clip.mov", .video, Self.footage)
        func probed(_ change: (inout MediaMetadata) -> Void) -> ProbedMedia {
            var metadata = Self.footage
            change(&metadata)
            return ProbedMedia(kind: .video, metadata: metadata)
        }

        // Within a frame or so is the same.
        #expect(MediaRelinker.differences(between: item, and: probed { $0.duration = CMTime(value: 301, timescale: 30) }).isEmpty)
        // Stored turned, but upright the same size, is the same.
        #expect(MediaRelinker.differences(between: item, and: probed {
            $0.naturalSize = CGSize(width: 1080, height: 1920)
            $0.rotation = 90
        }).isEmpty)
        #expect(MediaRelinker.differences(between: item, and: probed { $0.naturalSize = CGSize(width: 1080, height: 1920) })
                == [.size(expected: CGSize(width: 1920, height: 1080), found: CGSize(width: 1080, height: 1920))])
        #expect(MediaRelinker.differences(between: item, and: probed { $0.duration = CMTime(value: 5, timescale: 1) })
                == [.duration(expected: Self.footage.duration, found: CMTime(value: 5, timescale: 1))])
        #expect(MediaRelinker.differences(between: item, and: probed { $0.nominalFrameRate = 25 })
                == [.frameRate(expected: 30, found: 25)])
        #expect(MediaRelinker.differences(between: item, and: ProbedMedia(kind: .audio, metadata: MediaMetadata()))
                == [.kind(expected: .video, found: .audio)])
    }

    @Test(.enabled(if: Samples.isAvailable))
    func findsMissingMediaInAFolder() async throws {
        let files = MediaRelinker.mediaFiles(in: Samples.directory)
        #expect(files.contains { $0.lastPathComponent == "IMG_3311.mp4" })
        #expect(files.contains { $0.lastPathComponent == "IMG_2459.JPG" })

        let landscape = try await MediaProbe.probe(Samples.url("IMG_3311.mp4"))
        let photo = try await MediaProbe.probe(Samples.url("IMG_2459.JPG"))
        let same = Self.item("img_3311.MP4", .video, landscape.metadata)
        // Named for a portrait clip, but imported as the landscape one.
        let misnamed = Self.item("IMG_3312.mp4", .video, landscape.metadata)
        let still = Self.item("IMG_2459.heic", .image, photo.metadata)
        let nowhere = Self.item("Nowhere.mov")

        let matches = await MediaRelinker.match([same, misnamed, still, nowhere], among: files)
        let byID = Dictionary(uniqueKeysWithValues: matches.map { ($0.mediaID, $0) })
        #expect(byID[same.id]?.url.lastPathComponent == "IMG_3311.mp4")
        #expect(byID[same.id]?.isConfirmed == true)
        // Found by name, but it isn't the same media, and says how.
        let other = try #require(byID[misnamed.id])
        #expect(other.url.deletingPathExtension().lastPathComponent == "IMG_3312")
        #expect(other.differences.contains { if case .size = $0 { true } else { false } })
        // The same name with another extension.
        #expect(byID[still.id]?.url.lastPathComponent == "IMG_2459.JPG")
        #expect(byID[still.id]?.isConfirmed == true)
        #expect(byID[nowhere.id] == nil)
    }
}
