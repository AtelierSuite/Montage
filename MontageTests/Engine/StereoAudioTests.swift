@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// Keeps copies of media in a folder of its own.
private struct FolderStore: DerivedMediaStore {
    let folder: URL

    func url(for mediaID: MediaItem.ID, _ kind: DerivedMedia) -> URL? {
        folder.appending(path: "\(kind.rawValue)-\(mediaID.uuidString).m4a")
    }
}

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// A folder of its own for a test, with a mono file of a steady tone.
private struct MonoFixture {
    let folder: URL
    let url: URL
    let item: MediaItem
    let store: FolderStore

    init() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "StereoAudioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        url = folder.appending(path: "tone.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(48_000 * 2)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = 0.5 * sin(Float(index) * 2 * .pi * 440 / 48_000)
        }
        try file.write(from: buffer)
        file.close()
        item = MediaItem(
            name: "tone.caf", kind: .audio, location: .package(path: "tone.caf"),
            metadata: MediaMetadata(duration: seconds(2), audioChannelCount: 1, audioSampleRate: 48_000)
        )
        store = FolderStore(folder: folder)
    }

    var resolver: MediaResolver {
        let url = url
        return MediaResolver { _ in url }
    }

    func project(pan: Double?) -> Project {
        var pans: [Effect] = []
        if let pan {
            var effect = Pan()
            effect.position = Animatable(pan)
            pans = [Effect(.pan(effect))]
        }
        let clip = Clip(mediaID: item.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(2)), effects: pans)
        return Project(media: [item], tracks: [Track(kind: .audio, clips: [clip])])
    }

    func build(_ project: Project, findingCopies: Bool) async throws -> BuiltComposition {
        let resolver = findingCopies ? resolver.findingDerivedMedia(in: store) : resolver
        let built = try await CompositionBuilder(project: project, mediaResolver: resolver).build()
        #expect(built.skippedClips.isEmpty)
        return built
    }

    func remove() {
        try? FileManager.default.removeItem(at: folder)
    }
}

struct StereoAudioTests {
    @Test func onlyMonoMediaThatsPannedNeedsACopy() throws {
        let fixture = try MonoFixture()
        defer { fixture.remove() }
        #expect(DerivedMedia.stereoAudio.applies(to: fixture.item))
        #expect(DerivedMedia.stereoAudio.media(neededIn: fixture.project(pan: -1)).map(\.id) == [fixture.item.id])
        #expect(DerivedMedia.stereoAudio.media(neededIn: fixture.project(pan: nil)).isEmpty)

        var stereo = fixture.item
        stereo.metadata.audioChannelCount = 2
        var project = fixture.project(pan: -1)
        project.media = [stereo]
        #expect(DerivedMedia.stereoAudio.media(neededIn: project).isEmpty)

        // A video's sound, detached, isn't heard from its own clip.
        var video = fixture.item
        video.kind = .video
        var detached = fixture.project(pan: -1)
        detached.media = [video]
        detached.tracks[0].kind = .video
        detached.tracks[0].update(detached.tracks[0].clips[0].id) { $0.isAudioDetached = true }
        #expect(DerivedMedia.stereoAudio.media(neededIn: detached).isEmpty)
    }

    @Test func makesAStereoCopyTimedAsTheOriginal() async throws {
        let fixture = try MonoFixture()
        defer { fixture.remove() }
        let cache = DerivedMediaCache(store: fixture.store)
        let made = try #require(await cache.make(.stereoAudio, for: fixture.item, from: fixture.url))
        #expect(fixture.store.existingURL(for: fixture.item.id, .stereoAudio) == made)

        let asset = AVURLAsset(url: made)
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let description = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee.mChannelsPerFrame == 2)
        #expect(abs(try await track.load(.timeRange).duration.seconds - 2) < 0.01)
        // Only once.
        #expect(await cache.makeAll(.stereoAudio, neededIn: fixture.project(pan: 1), resolver: fixture.resolver) == false)
    }

    @Test func monoMediaIsPannedThroughItsStereoCopy() async throws {
        let fixture = try MonoFixture()
        defer { fixture.remove() }
        let left = fixture.project(pan: -1)

        // Without a copy, a mono track can't be panned.
        let unpanned = try await RenderedAudio.read(try await fixture.build(left, findingCopies: true))
        let level = unpanned.rms(\.left, 0.1, 1.9)
        #expect(level > 0.1)
        #expect(abs(unpanned.rms(\.right, 0.1, 1.9) - level) < 0.01 * level)

        let cache = DerivedMediaCache(store: fixture.store)
        #expect(await cache.makeAll(.stereoAudio, neededIn: left, resolver: fixture.resolver))
        let built = try await fixture.build(left, findingCopies: true)
        let track = try #require(built.composition.tracks(withMediaType: .audio).first as? AVCompositionTrack)
        #expect(track.segments.first?.sourceURL == fixture.store.url(for: fixture.item.id, .stereoAudio))

        // Fully left, and as loud overall as it was centred.
        let panned = try await RenderedAudio.read(built)
        #expect(panned.rms(\.right, 0.1, 1.9) < 1e-4)
        #expect(abs(panned.rms(\.left, 0.1, 1.9) - level * 2.0.squareRoot()) < 0.02 * level)

        // Centred, the copy sounds just as the original did.
        let centred = try await RenderedAudio.read(try await fixture.build(fixture.project(pan: 0), findingCopies: true))
        #expect(abs(centred.rms(\.left, 0.1, 1.9) - level) < 0.02 * level)
        #expect(abs(centred.rms(\.right, 0.1, 1.9) - level) < 0.02 * level)
        let original = try await RenderedAudio.read(try await fixture.build(fixture.project(pan: nil), findingCopies: false))
        #expect(abs(original.rms(\.left, 0.1, 1.9) - level) < 0.02 * level)
    }

    @Test func soundThatStartsLateStartsAsLateInTheCopy() async throws {
        let fixture = try MonoFixture()
        defer { fixture.remove() }
        // The tone, half a second into a movie.
        let tone = AVURLAsset(url: fixture.url)
        let toneTrack = try #require(try await tone.loadTracks(withMediaType: .audio).first)
        let composition = AVMutableComposition()
        let track = try #require(composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid))
        try track.insertTimeRange(try await toneTrack.load(.timeRange), of: toneTrack, at: seconds(0.5))
        let late = fixture.folder.appending(path: "late.mov")
        let session = try #require(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: late, as: .mov)

        let copy = fixture.folder.appending(path: "late-stereo.m4a")
        try await DerivedMediaGenerator.make(.stereoAudio, from: late, to: copy)
        let original = try #require(try await AVURLAsset(url: late).loadTracks(withMediaType: .audio).first)
        let stereo = try #require(try await AVURLAsset(url: copy).loadTracks(withMediaType: .audio).first)
        let (originalRange, stereoRange) = (try await original.load(.timeRange), try await stereo.load(.timeRange))
        #expect(abs(stereoRange.end.seconds - originalRange.end.seconds) < 0.02)
        let audio = try await RenderedAudio.read(AVURLAsset(url: copy))
        #expect(audio.rms(\.left, 0, 0.45) < 1e-4)
        #expect(audio.rms(\.left, 0.6, 2.4) > 0.1)
    }
}
