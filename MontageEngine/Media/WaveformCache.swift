import Foundation

/// Keeps media's waveforms once read, and reads each only once however many
/// clips ask for it at a time. Reading a long video's sound takes a while, so
/// a store on disk, such as the project package's cache, can stand behind it
/// through `WaveformStore` and keep them between launches.
public actor WaveformCache {
    private let store: (any WaveformStore)?
    private var waveforms: [MediaItem.ID: WaveformPeaks] = [:]
    private var inFlight: [MediaItem.ID: Task<WaveformPeaks?, Never>] = [:]

    public init(store: (any WaveformStore)? = nil) {
        self.store = store
    }

    /// The item's waveform, read from its file if it hasn't been. Nil for a
    /// still image, media without sound, or a file that can't be read.
    public func waveform(for item: MediaItem, at url: URL) async -> WaveformPeaks? {
        guard item.kind != .image else { return nil }
        if let waveform = waveforms[item.id] { return waveform }
        if let task = inFlight[item.id] { return await task.value }

        let store = store
        let id = item.id
        let task = Task.detached(priority: .utility) { () -> WaveformPeaks? in
            if let waveform = await store?.waveform(for: id) { return waveform }
            guard let waveform = try? await WaveformGenerator.peaks(of: url) else { return nil }
            await store?.store(waveform, for: id)
            return waveform
        }
        inFlight[id] = task
        let waveform = await task.value
        inFlight[id] = nil
        if let waveform { waveforms[id] = waveform }
        return waveform
    }

    /// The waveform if it's been read already, without reading it.
    public func cachedWaveform(for mediaID: MediaItem.ID) -> WaveformPeaks? {
        waveforms[mediaID]
    }

    /// Forgets an item's waveform, such as when it's relinked to another file.
    public func removeWaveform(for mediaID: MediaItem.ID) {
        waveforms[mediaID] = nil
    }
}

/// Somewhere waveforms outlast the cache in memory, such as files in the
/// project package's cache.
public protocol WaveformStore: Sendable {
    func waveform(for mediaID: MediaItem.ID) async -> WaveformPeaks?
    func store(_ waveform: WaveformPeaks, for mediaID: MediaItem.ID) async
}

/// A store on disk for everything made from media: thumbnails and
/// waveforms, such as the project package's cache.
public protocol MediaCacheStore: ThumbnailStore, WaveformStore {
    /// Throws away everything made from a media item.
    func removeCache(for mediaID: MediaItem.ID)
}

// MARK: - Encoding

extension WaveformPeaks {
    private static let magic = Data("MWF1".utf8)

    /// The peaks as a small file: a header, then one byte a peak, which is
    /// as fine as a waveform is ever drawn.
    public func encoded() -> Data {
        var data = Self.magic
        withUnsafeBytes(of: peaksPerSecond.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: peaks.map { UInt8((min(max($0, 0), 1) * 255).rounded()) })
        return data
    }

    /// Reads peaks written by `encoded()`, or nil for anything else.
    public init?(encoded data: Data) {
        let header = Self.magic.count + MemoryLayout<UInt64>.size
        guard data.count >= header, data.prefix(Self.magic.count) == Self.magic else { return nil }
        var bits: UInt64 = 0
        for (shift, byte) in data[data.startIndex + Self.magic.count..<data.startIndex + header].enumerated() {
            bits |= UInt64(byte) << (8 * UInt64(shift))
        }
        let rate = Double(bitPattern: bits)
        guard rate.isFinite, rate > 0 else { return nil }
        self.init(peaksPerSecond: rate, peaks: data.dropFirst(header).map { Float($0) / 255 })
    }
}
