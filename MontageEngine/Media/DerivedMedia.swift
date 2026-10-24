@preconcurrency import AVFoundation
import CryptoKit
import Foundation

/// Files made from a media item's own for the composition to play in its
/// place. They have the same timing as the original, so a clip's source
/// range means the same in either, and they can be made again at any time.
public enum DerivedMedia: String, CaseIterable, Sendable {
    /// Mono media's sound, on both channels of a stereo file, so it can be
    /// panned: a composition track's tap gets as many channels as its media
    /// has, and can't hand back more.
    case stereoAudio
    /// A smaller copy of a large video's picture, for preview to decode
    /// more easily. Export always uses the original.
    case proxy

    /// Whether an item gets this kind of copy made of it.
    public func applies(to item: MediaItem) -> Bool {
        switch self {
        case .stereoAudio:
            item.kind != .image && item.metadata.audioChannelCount == 1
        case .proxy:
            item.kind == .video && Self.needsProxy(item.metadata.presentationSize)
        }
    }

    /// The name of an item's copy: its ID, then a digest of where its file is
    /// and what it's like, so a copy made from another file, as before a
    /// relink or after one is undone, isn't taken for this one's.
    public func fileName(for item: MediaItem) -> String {
        "\(item.id.uuidString)-\(Self.sourceKey(of: item)).\(pathExtension)"
    }

    public var pathExtension: String {
        switch self {
        case .stereoAudio: "m4a"
        case .proxy: "mov"
        }
    }

    /// A short digest of an item's location and metadata.
    public static func sourceKey(of item: MediaItem) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(item.location)) ?? Data()
        let metadata = (try? encoder.encode(item.metadata)) ?? Data()
        return SHA256.hash(data: data + metadata).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The largest picture, on its longer and shorter sides, played as it is.
    /// Anything bigger, such as 4K, gets a proxy.
    public static let largestWithoutProxy = CGSize(width: 1920, height: 1080)
    /// The size proxies are made to fit in.
    public static let proxyPreset = AVAssetExportPreset960x540

    static func needsProxy(_ size: CGSize) -> Bool {
        let long = max(size.width, size.height), short = min(size.width, size.height)
        return long > largestWithoutProxy.width || short > largestWithoutProxy.height
    }

    /// The media in a project that's played through this kind of copy:
    /// mono media under a clip with a pan effect turned on, on a track that
    /// isn't muted, or large video on a video track that isn't hidden.
    public func media(neededIn project: Project) -> [MediaItem] {
        var needed = Set<MediaItem.ID>()
        for track in project.tracks {
            for clip in track.clips {
                // Text and shapes have no media to copy.
                guard let mediaID = clip.mediaID else { continue }
                switch self {
                case .stereoAudio:
                    let isHeard = !track.isMuted && (track.kind == .audio || !clip.isAudioDetached)
                    let isPanned = clip.effects.contains { effect in
                        if case .pan = effect.kind { effect.isEnabled } else { false }
                    }
                    if isHeard, isPanned { needed.insert(mediaID) }
                case .proxy:
                    if track.kind == .video, !track.isHidden { needed.insert(mediaID) }
                }
            }
        }
        return project.media.filter { needed.contains($0.id) && applies(to: $0) }
    }
}

/// Where copies made from media are kept, such as the project package's
/// cache.
public protocol DerivedMediaStore: Sendable {
    /// Where an item's copy goes, whether or not it's been made, named by
    /// `DerivedMedia.fileName(for:)`. Nil when there's nowhere to keep it.
    func url(for item: MediaItem, _ kind: DerivedMedia) -> URL?
    /// Makes ready the folder a copy at `url` goes in, returning false if it
    /// can't go there any more, such as when the project has been moved or
    /// deleted while it was being made.
    func prepareFolder(for url: URL) -> Bool
    /// Throws away every copy made from a media item, whatever file it was
    /// made from.
    func removeCopies(for mediaID: MediaItem.ID)
}

extension DerivedMediaStore {
    public func removeCopies(for mediaID: MediaItem.ID) {}

    public func prepareFolder(for url: URL) -> Bool {
        (try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil
    }

    /// The item's copy, if one's been made from its file as it is now.
    public func existingURL(for item: MediaItem, _ kind: DerivedMedia) -> URL? {
        guard let url = url(for: item, kind), FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}

/// Makes copies of media into a store, each only once however many ask for
/// it at a time.
public actor DerivedMediaCache {
    public nonisolated let store: (any DerivedMediaStore)?
    private var inFlight: [Key: Task<URL?, Never>] = [:]
    /// The copies that couldn't be made, by the file they were made from,
    /// so they aren't tried again on every edit.
    private var failed: Set<Source> = []

    private struct Key: Hashable {
        let mediaID: MediaItem.ID
        let kind: DerivedMedia
    }

    private struct Source: Hashable {
        let mediaID: MediaItem.ID
        let kind: DerivedMedia
        let sourceKey: String

        init(_ item: MediaItem, _ kind: DerivedMedia) {
            mediaID = item.id
            self.kind = kind
            sourceKey = DerivedMedia.sourceKey(of: item)
        }
    }

    public init(store: (any DerivedMediaStore)?) {
        self.store = store
    }

    /// The item's copy, made from the file at `url` if it hasn't been. Nil
    /// when there's nowhere to keep it, or it couldn't be made.
    public func make(_ kind: DerivedMedia, for item: MediaItem, from url: URL) async -> URL? {
        guard let store, let destination = store.url(for: item, kind) else { return nil }
        if FileManager.default.fileExists(atPath: destination.path) { return destination }
        // Not again from the same file: pointed at another, or its metadata
        // read again, it's tried afresh.
        guard !failed.contains(Source(item, kind)) else { return nil }
        let key = Key(mediaID: item.id, kind: kind)
        if let task = inFlight[key] { return await task.value }
        let task = Task.detached(priority: .utility) { () -> URL? in
            // Made in a temporary folder, then moved into the store wherever
            // it is by then: the project may have been moved or renamed.
            let partial = FileManager.default.temporaryDirectory
                .appending(path: "MontageDerivedMedia", directoryHint: .isDirectory)
                .appending(path: "\(UUID().uuidString).\(kind.pathExtension)", directoryHint: .notDirectory)
            defer { try? FileManager.default.removeItem(at: partial) }
            do {
                try await DerivedMediaGenerator.make(kind, from: url, to: partial)
                guard let destination = store.url(for: item, kind), store.prepareFolder(for: destination) else { return nil }
                _ = try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: partial, to: destination)
                return destination
            } catch {
                return nil
            }
        }
        inFlight[key] = task
        // Cancelled, such as when the project closes, the copy stops being
        // made rather than running on to the end.
        let made = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inFlight[key] = nil
        // A copy given up on isn't one that failed.
        if made == nil, !Task.isCancelled, !task.isCancelled { failed.insert(Source(item, kind)) }
        return made
    }

    /// Whether the item's copy couldn't be made from its file as it is.
    public func hasFailed(_ kind: DerivedMedia, for item: MediaItem) -> Bool {
        failed.contains(Source(item, kind))
    }

    /// Tries an item's copies again next time, such as once it's relinked.
    public func forgetFailures(for mediaID: MediaItem.ID) {
        failed = failed.filter { $0.mediaID != mediaID }
    }

    /// Makes every copy of a kind the project needs that hasn't been made,
    /// one at a time. Returns whether any were made.
    @discardableResult
    public func makeAll(_ kind: DerivedMedia, neededIn project: Project, resolver: MediaResolver) async -> Bool {
        var madeAny = false
        for item in kind.media(neededIn: project) where store?.existingURL(for: item, kind) == nil {
            guard !Task.isCancelled else { break }
            guard let url = resolver.url(for: item) else { continue }
            if await make(kind, for: item, from: url) != nil { madeAny = true }
        }
        return madeAny
    }
}

/// Makes the files of `DerivedMedia`.
public enum DerivedMediaGenerator {
    public enum Failure: Error {
        case noTrack
        case failed((any Error)?)
    }

    /// Makes a kind of copy of the media at `source` at `destination`,
    /// replacing whatever's there. It's written beside it first and moved
    /// into place when done, so a copy that's there is always whole.
    public static func make(_ kind: DerivedMedia, from source: URL, to destination: URL) async throws {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appending(path: ".\(UUID().uuidString).\(destination.pathExtension)", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: partial) }
        switch kind {
        case .stereoAudio: try await makeStereoAudio(from: source, to: partial)
        case .proxy: try await makeProxy(from: source, to: partial)
        }
        _ = try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// The main audio track's sound on both channels, losslessly, as an
    /// `.m4a`: read through the same mixer that plays mono media centred in a
    /// composition, so it sounds just as the original does until it's panned.
    static func makeStereoAudio(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        var main = tracks.first
        for track in tracks where try await track.load(.isEnabled) {
            main = track
            break
        }
        guard let track = main else { throw Failure.noTrack }
        let descriptions = try await track.load(.formatDescriptions)
        let sampleRate = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate } ?? 48_000
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layoutData, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)

        let writer = try AVAssetWriter(outputURL: destination, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatAppleLossless, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVChannelLayoutKey: layoutData, AVEncoderBitDepthHintKey: 24,
        ])
        input.expectsMediaDataInRealTime = false
        writer.add(input)

        // Reading blocks until the next buffer is decoded, for as long as the
        // media runs; on a queue of its own, so it doesn't hold a shared
        // thread the readers and writers it waits on may need.
        try await withTaskExecutorPreference(DispatchQueue(label: "Montage.StereoCopy")) {
            try await copy(from: output, of: reader, to: input, of: writer)
        }
    }

    private static func copy(
        from output: AVAssetReaderOutput, of reader: AVAssetReader, to input: AVAssetWriterInput, of writer: AVAssetWriter
    ) async throws {
        guard reader.startReading(), writer.startWriting() else {
            throw Failure.failed(reader.error ?? writer.error)
        }
        // From the start of the media, so sound that starts late in it
        // starts as late in the copy.
        writer.startSession(atSourceTime: .zero)
        var started = false
        do {
            while let buffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                started = true
                while !input.isReadyForMoreMediaData {
                    try await Task.sleep(for: .milliseconds(5))
                }
                guard input.append(buffer) else { throw Failure.failed(writer.error) }
            }
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            throw error
        }
        guard reader.status == .completed, started else {
            writer.cancelWriting()
            throw Failure.failed(reader.error)
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw Failure.failed(writer.error) }
    }

    /// The media's picture at a smaller size, as a `.mov` that fits in
    /// `DerivedMedia.proxyPreset`. Only its picture is played, so only its
    /// video track is copied, turned and timed as it is in the original.
    static func makeProxy(from source: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: source, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noTrack }
        let (timeRange, transform, _) = try await video.load(.timeRange, .preferredTransform, .formatDescriptions)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.failed(nil)
        }
        try track.insertTimeRange(timeRange, of: video, at: timeRange.start)
        track.preferredTransform = transform
        guard let session = AVAssetExportSession(asset: composition, presetName: DerivedMedia.proxyPreset) else {
            throw Failure.failed(nil)
        }
        nonisolated(unsafe) let exporting = session
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await session.export(to: destination, as: .mov)
        } onCancel: {
            exporting.cancelExport()
        }
    }
}

extension MediaResolver {
    /// The resolver, also finding the copies of media that have been made
    /// in a store.
    public func findingDerivedMedia(in store: (any DerivedMediaStore)?) -> MediaResolver {
        guard let store else { return self }
        return addingDerivedMedia { item, kind in store.existingURL(for: item, kind) }
    }
}
