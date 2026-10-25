import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

/// Reads a CMX 3600 edit decision list (`.edl`), the plain-text cut list
/// most editors export.
///
/// An EDL doesn't say what frame rate its timecode counts, so the rate is
/// taken from its FCM lines and its frame numbers: drop frame is 29.97,
/// and otherwise 30 is assumed unless the frame numbers point elsewhere.
/// Once the media is found (see `ProjectInterchange.gatherMedia`) the list
/// is read again at the media's own rate, if that's different. Either way
/// the report says which rate was used.
///
/// Record timecode is counted from the hour the list starts in, so a list
/// starting at 01:00:00:00, as most do, starts at the start of the
/// timeline; a list starting more than ten minutes into its hour, as one
/// with a leader before the hour does, starts at its first event. Source
/// timecode is taken as time from the start of the media.
///
/// Picture goes on one video track (keyed foregrounds on a second), and
/// sound on an audio track for each channel. Where a picture event and a
/// sound event are of the same stretch of the same file, they're made one
/// clip, which plays both.
struct EDLImporter {
    private let document: EDLDocument
    private let baseURL: URL?
    private let rate: EDLRate
    private var report = ImportReport(format: .edl)
    /// The record timecode at the start of the timeline.
    private var origin = 0

    /// Reads an EDL. `rate` is the rate to count its timecode at, when
    /// that's known; otherwise it's guessed, as the report then says.
    static func read(_ data: Data, baseURL: URL?, rate: EDLRate? = nil) throws -> ImportedProject {
        guard let text = text(of: data), EDLDocument.looksLikeEDL(text) else { throw InterchangeError.unsupportedFormat }
        let document = EDLDocument(text: text)
        guard !document.events.isEmpty else { throw InterchangeError.noTimeline }
        let guessed = rate == nil
        var importer = EDLImporter(document: document, baseURL: baseURL, rate: rate ?? guessRate(for: document))
        var imported = importer.run(rateIsGuessed: guessed)
        if guessed {
            let metadata = imported.project.media.map(\.metadata)
            imported.conformToMedia = { gathered, store in
                await conform(gathered, store: store, data: data, baseURL: baseURL, document: document, unprobed: metadata)
            }
        }
        return imported
    }

    /// Whether data reads as an EDL rather than XML.
    static func canRead(_ data: Data) -> Bool {
        guard let text = text(of: data.prefix(4096)) else { return false }
        return EDLDocument.looksLikeEDL(text)
    }

    /// The text of the file: UTF-8, or Windows Latin 1, as older systems
    /// write it.
    private static func text(of data: Data) -> String? {
        var data = data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
    }

    /// The rate to read the list at with nothing else to go on: 29.97 in
    /// drop frame, else 30, unless the frame numbers go past what that
    /// rate counts.
    ///
    /// Frame numbers can show a lower rate too, given enough of them: a
    /// list at 30 with 16 frame numbers past zero all but surely has one at
    /// 25 or more, so if the highest is 24 it's taken as 25. Telling 24 from
    /// 25 by a highest of 23 takes many more, 72. Lists with fewer, or
    /// whose cuts are all on whole seconds, stay at 30.
    static func guessRate(for document: EDLDocument) -> EDLRate {
        let frames = document.events.flatMap { [$0.sourceIn, $0.sourceOut, $0.recordIn, $0.recordOut] }.map(\.frames)
        let highestFrame = frames.max() ?? 0
        if document.hasDropFrame { return highestFrame >= 30 ? .ntsc60 : .ntsc30 }
        if highestFrame >= 30 { return .fps60 }
        let counted = frames.filter { $0 > 0 }.count
        if highestFrame == 24, counted >= 16 { return EDLRate(frameDuration: CMTime(value: 1, timescale: 25)) }
        if highestFrame <= 23, counted >= 72 { return EDLRate(frameDuration: CMTime(value: 1, timescale: 24)) }
        return .fps30
    }

    /// The record timecode at the start of the timeline: the hour the list
    /// starts in, so a list starting at 01:00:00:00, or a little after,
    /// keeps its place from there. A list starting well into its hour, as
    /// one with a leader before 01:00:00:00 does, starts at its first event.
    static func origin(of first: EDLDocument.Event, rate: EDLRate) -> Int {
        let start = first.recordIn.frameCount(at: rate, dropFrame: first.isDropFrame)
        let hour = EDLTimecode(hours: first.recordIn.hours, minutes: 0, seconds: 0, frames: 0)
            .frameCount(at: rate, dropFrame: first.isDropFrame)
        return start - hour <= rate.timecodeBase * 600 ? hour : start
    }

    private init(document: EDLDocument, baseURL: URL?, rate: EDLRate) {
        self.document = document
        self.baseURL = baseURL
        self.rate = rate
    }

    // MARK: - Reading

    /// A clip on its way to a track.
    private struct Placed {
        var clip: Clip
        var kind: Track.Kind
        var lane: Int
        var name: String
        /// The key of the media it's of, to find its other half by.
        var mediaKey: String
        /// How much of its end is the outgoing half of a transition, not in
        /// the list as its own.
        var overlap: CMTime = .zero

        /// Where it ends as the list has it, before any transition.
        var listedRange: CMTimeRange {
            CMTimeRange(start: clip.timelineStart, duration: clip.duration - overlap)
        }
    }

    private mutating func run(rateIsGuessed: Bool) -> ImportedProject {
        report.add(rateIsGuessed ? .frameRateAssumed(rate.displayString) : .frameRateFromMedia(rate.displayString))
        let events = document.events
        if let first = events.min(by: { frames($0.recordIn, $0) < frames($1.recordIn, $1) }) {
            origin = Self.origin(of: first, rate: rate)
        }

        var settings = ProjectSettings()
        settings.frameDuration = rate.frameDuration
        var media = ImportedMedia()
        let mediaItems = makeMedia(for: events, into: &media, renderSize: settings.renderSize)

        var placed: [Placed] = []
        var index = 0
        while index < events.count {
            // The lines of one event: two for a transition.
            var group = [events[index]]
            while index + group.count < events.count, events[index + group.count].number == events[index].number {
                group.append(events[index + group.count])
            }
            index += group.count
            place(group, items: mediaItems, into: &placed)
        }
        let merged = mergeSoundInStep(placed)

        var assembler = TimelineAssembler()
        for entry in merged {
            assembler.add(entry.clip, kind: entry.kind, lane: entry.lane, name: entry.name)
        }
        for (range, lane) in transitions {
            assembler.addTransition(range, lane: lane)
        }
        var project = Project(settings: settings, media: media.items)
        project.tracks = assembler.tracks(report: &report)
        for locator in document.locators {
            let count = locator.time.frameCount(at: rate, dropFrame: locator.isDropFrame) - origin
            guard count >= 0 else { continue }
            project.addMarker(at: rate.time(count), name: locator.name)
        }
        for number in document.splitEdits {
            report.add(.setting(name: "Split edit"), clipName: events.first { $0.number == number }?.clipName)
        }
        return ImportedProject(project: project, report: report, name: document.title, mediaSources: media.sources)
    }

    private var transitions: [(CMTimeRange, Int)] = []

    private func frames(_ timecode: EDLTimecode, _ event: EDLDocument.Event) -> Int {
        timecode.frameCount(at: rate, dropFrame: event.isDropFrame)
    }

    // MARK: - Media

    /// What's known of a file from the events that use it.
    private struct MediaUse {
        var key: String
        var url: URL?
        var name: String
        var hasVideo = false
        var hasAudio = false
    }

    /// The key an event's file is known by: its path, else its clip name,
    /// else its reel.
    private func mediaKey(of event: EDLDocument.Event) -> String {
        event.sourceFile ?? event.clipName ?? "reel:\(event.reel)"
    }

    /// A media item for each file the events use, in the order they're
    /// first used. Files with no path are left to be found by name, or
    /// relinked.
    private func makeMedia(
        for events: [EDLDocument.Event], into media: inout ImportedMedia, renderSize: CGSize
    ) -> [String: MediaItem] {
        var uses: [MediaUse] = []
        var indices: [String: Int] = [:]
        for event in events where !event.isBlack {
            let key = mediaKey(of: event)
            if indices[key] == nil {
                let url = ImportedMedia.url(from: event.sourceFile, relativeTo: baseURL)
                let name = url?.lastPathComponent ?? event.clipName ?? event.reel
                indices[key] = uses.count
                uses.append(MediaUse(key: key, url: url, name: name))
            }
            let index = indices[key]!
            uses[index].hasVideo = uses[index].hasVideo || event.hasVideo
            uses[index].hasAudio = uses[index].hasAudio || !event.audioChannels.isEmpty
        }

        var items: [String: MediaItem] = [:]
        for use in uses {
            let fileType = UTType(filenameExtension: ((use.url?.lastPathComponent ?? use.name) as NSString).pathExtension)
            let kind: MediaItem.Kind = if fileType?.conforms(to: .image) == true { .image }
                else if fileType?.conforms(to: .audio) == true { .audio }
                else if use.hasVideo { .video }
                else { .audio }
            // Its length isn't known until it's found: the list's source
            // points are timecode, which may start anywhere.
            var metadata = MediaMetadata()
            if kind != .audio { metadata.naturalSize = renderSize }
            if kind != .image, use.hasAudio || kind == .audio {
                metadata.audioChannelCount = 2
                metadata.audioSampleRate = 48000
            }
            items[use.key] = media.item(key: use.key, url: use.url, name: use.name, kind: kind, metadata: metadata)
        }
        return items
    }

    /// The stretch of the source an event plays, in frames: as long as it
    /// lasts on the timeline, as Montage plays everything at normal speed.
    private func sourceRange(of event: EDLDocument.Event) -> (start: Int, duration: Int) {
        let sourceIn = frames(event.sourceIn, event)
        let sourceOut = frames(event.sourceOut, event)
        let duration = max(0, frames(event.recordOut, event) - frames(event.recordIn, event))
        // In reverse, the source runs back from its in point.
        let isReverse = (event.speed ?? 0) < 0 || sourceOut < sourceIn
        let start = isReverse ? max(0, min(sourceIn, sourceOut)) : sourceIn
        return (start, duration)
    }

    // MARK: - Events

    private mutating func place(_ group: [EDLDocument.Event], items: [String: MediaItem], into placed: inout [Placed]) {
        guard let incoming = group.last else { return }
        let outgoing = group.count > 1 ? group.first : nil
        let start = rate.time(frames(incoming.recordIn, incoming) - origin)

        if incoming.isTransition {
            let length = incoming.transitionFrames > 0 ? incoming.transitionFrames
                : frames(incoming.recordOut, incoming) - frames(incoming.recordIn, incoming)
            let range = CMTimeRange(start: start, duration: rate.time(length))
            let name: String = switch incoming.edit {
            case .wipe(let code): incoming.effectName ?? (code.isEmpty ? "Wipe" : "Wipe \(code)")
            default: incoming.effectName ?? "Dissolve"
            }
            report.add(.transition(name: name), clipName: incoming.clipName, time: start)
            for lane in lanes(of: incoming) {
                transitions.append((range, lane.lane))
            }
            // The outgoing material plays on through the transition; into
            // black, only to the middle of it, where the cut goes.
            let overlap = incoming.isBlack ? length / 2 : length
            if let outgoing, !outgoing.isBlack {
                for entry in clips(for: outgoing, items: items, extendedBy: overlap) {
                    append(entry, to: &placed)
                }
            } else if outgoing == nil {
                extendLastClip(endingAt: start, by: overlap, lanes: lanes(of: incoming), in: &placed)
            }
            // Out of black, the incoming material starts in the middle.
            if outgoing?.isBlack == true, !incoming.isBlack {
                let cut = start + rate.time(length / 2)
                for entry in clips(for: incoming, items: items, extendedBy: 0) {
                    guard var trimmed = entry.clip.trimmed(to: CMTimeRange(start: cut, end: entry.clip.timelineRange.end)) else {
                        continue
                    }
                    if !trimmed.content.hasSourceTime { trimmed.sourceRange.start = .zero }
                    var entry = entry
                    entry.clip = trimmed
                    append(entry, to: &placed)
                }
                return
            }
        } else if let outgoing, !outgoing.isBlack {
            for entry in clips(for: outgoing, items: items, extendedBy: 0) {
                append(entry, to: &placed)
            }
        }
        if case .key = incoming.edit {
            report.add(.setting(name: "Key"), clipName: incoming.clipName, time: start)
        }
        guard !incoming.isBlack else { return }
        for entry in clips(for: incoming, items: items, extendedBy: 0) {
            append(entry, to: &placed)
        }
    }

    /// The lanes an event goes on: video on the first, a keyed foreground
    /// on the second, and each audio channel on its own.
    private func lanes(of event: EDLDocument.Event) -> [(kind: Track.Kind, lane: Int)] {
        var lanes: [(kind: Track.Kind, lane: Int)] = []
        if event.hasVideo {
            if case .key(background: false) = event.edit { lanes.append((.video, 1)) } else { lanes.append((.video, 0)) }
        }
        // A stereo pair is one clip: Montage plays the file's sound whole.
        var channels = event.audioChannels
        if channels.contains(1) && channels.contains(2) { channels.removeAll { $0 == 2 } }
        lanes += channels.map { (.audio, 1 - $0) }
        return lanes
    }

    /// The clips an event makes, one for each lane it goes on.
    private mutating func clips(for event: EDLDocument.Event, items: [String: MediaItem], extendedBy extra: Int) -> [Placed] {
        guard let item = items[mediaKey(of: event)] else { return [] }
        let source = sourceRange(of: event)
        let duration = source.duration + extra
        guard duration > 0 else { return [] }
        let start = rate.time(frames(event.recordIn, event) - origin)
        let name = event.clipName ?? item.name

        let sourceLength = abs(frames(event.sourceOut, event) - frames(event.sourceIn, event))
        if let speed = event.speed, abs(speed - Double(rate.timecodeBase)) > 0.05 {
            report.add(.speedChange, clipName: name, time: start)
        } else if event.speed == nil, item.kind != .image, abs(sourceLength - source.duration) > 1, sourceLength > 0 {
            // Source and record lengths that don't match make a speed change too.
            report.add(.speedChange, clipName: name, time: start)
        }

        let lanes = lanes(of: event)
        let hasVideoLane = lanes.contains { $0.kind == .video }
        return lanes.compactMap { lane in
            // A picture only event of a file with sound plays only its picture.
            if lane.kind == .audio, hasVideoLane, item.kind != .audio { return nil }
            var clip = Clip(
                content: item.content,
                sourceRange: CMTimeRange(
                    start: item.kind == .image ? .zero : rate.time(source.start), duration: rate.time(duration)
                ),
                timelineStart: start
            )
            if lane.kind == .video, item.kind == .video, event.audioChannels.isEmpty {
                clip.isAudioDetached = true
            }
            if lane.kind == .video, item.kind == .audio { return nil }
            return Placed(clip: clip, kind: lane.kind, lane: lane.lane, name: name, mediaKey: mediaKey(of: event),
                          overlap: rate.time(extra))
        }
    }

    /// Adds a clip, joining it onto the clip before it on its lane where it
    /// carries straight on from it, as the outgoing half of a transition
    /// does.
    private func append(_ entry: Placed, to placed: inout [Placed]) {
        if let index = placed.lastIndex(where: { $0.kind == entry.kind && $0.lane == entry.lane }) {
            let previous = placed[index]
            if previous.mediaKey == entry.mediaKey, previous.clip.content == entry.clip.content,
               previous.clip.timelineRange.end == entry.clip.timelineStart,
               previous.clip.content.hasSourceTime ? previous.clip.sourceRange.end == entry.clip.sourceRange.start : true {
                placed[index].clip.sourceRange.duration = previous.clip.duration + entry.clip.duration
                placed[index].overlap = entry.overlap
                return
            }
        }
        placed.append(entry)
    }

    /// A transition from the event before, written as one line: the clip
    /// before it plays on through it.
    private func extendLastClip(
        endingAt time: CMTime, by length: Int, lanes: [(kind: Track.Kind, lane: Int)], in placed: inout [Placed]
    ) {
        for lane in lanes {
            guard let index = placed.lastIndex(where: {
                $0.kind == lane.kind && $0.lane == lane.lane && $0.clip.timelineRange.end == time
            }) else { continue }
            placed[index].clip.sourceRange.duration = placed[index].clip.duration + rate.time(length)
            placed[index].overlap = placed[index].overlap + rate.time(length)
        }
    }

    /// Picture and sound events of the same stretch of a file, made one
    /// clip that plays both, as they were in the editor the list came from.
    private func mergeSoundInStep(_ placed: [Placed]) -> [Placed] {
        var result = placed
        var removed: Set<Int> = []
        for (index, entry) in placed.enumerated() where entry.kind == .audio {
            guard let match = result.indices.first(where: { candidate in
                let other = result[candidate]
                return other.kind == .video && other.lane == 0 && other.mediaKey == entry.mediaKey
                    && other.listedRange == entry.listedRange && other.clip.sourceRange.start == entry.clip.sourceRange.start
            }) else { continue }
            result[match].clip.isAudioDetached = false
            removed.insert(index)
        }
        return result.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }

    // MARK: - Conforming to the media

    /// Reads the list again at the rate of its media, once that's been
    /// found and probed, if it's not the rate that was guessed. The media
    /// as found is kept.
    /// Lines the list up with its media once that's been found: read at the
    /// media's rate, and with each found file's clips moved back by the
    /// timecode it starts at, as source points are given in it.
    private static func conform(
        _ gathered: ImportedProject, store: PackageMediaStore, data: Data, baseURL: URL?, document: EDLDocument,
        unprobed: [MediaMetadata]
    ) async -> ImportedProject {
        var conformed = conformRate(gathered, data: data, baseURL: baseURL, document: document, unprobed: unprobed)
        for (index, item) in conformed.project.media.enumerated()
        where index < unprobed.count && item.metadata != unprobed[index] && item.kind != .image {
            guard case .package(let path) = item.location, let url = store.stagedURL(forPackagePath: path),
                  let start = await MediaTimecode.start(of: url) else { continue }
            conformed.project.shiftSourceRanges(of: item.id, by: start)
        }
        return conformed
    }

    private static func conformRate(
        _ gathered: ImportedProject, data: Data, baseURL: URL?, document: EDLDocument, unprobed: [MediaMetadata]
    ) -> ImportedProject {
        let probed = gathered.project.media.enumerated().filter { index, item in
            item.kind == .video && index < unprobed.count && item.metadata != unprobed[index]
                && item.metadata.nominalFrameRate > 0
        }.map(\.element)
        let counts = Dictionary(grouping: probed.compactMap { EDLRate.nearest(to: $0.metadata.nominalFrameRate) }) {
            "\($0.frameDuration.value)/\($0.frameDuration.timescale)"
        }
        guard let common = counts.max(by: { $0.value.count < $1.value.count })?.value.first,
              !document.hasDropFrame || common.canDropFrames,
              var reread = try? read(data, baseURL: baseURL, rate: common),
              reread.project.media.count == gathered.project.media.count else { return gathered }

        // The items as gathered, with the new reading's clips pointed at them.
        var ids: [MediaItem.ID: MediaItem.ID] = [:]
        for (new, old) in zip(reread.project.media, gathered.project.media) {
            ids[new.id] = old.id
        }
        for (index, old) in gathered.project.media.enumerated() where old.metadata == unprobed[index] {
            // Not found: kept as the new reading made it, in its reserved place.
            reread.project.media[index].id = old.id
            reread.project.media[index].location = old.location
        }
        for (index, old) in gathered.project.media.enumerated() where old.metadata != unprobed[index] {
            reread.project.media[index] = old
        }
        reread.project.tracks = reread.project.tracks.map { track in
            var track = track
            for clip in track.clips {
                guard let id = clip.mediaID, let replacement = ids[id] else { continue }
                track.update(clip.id) {
                    $0.content = $0.content == .image(id) ? .image(replacement) : .media(replacement)
                }
            }
            return track
        }
        reread.mediaSources = gathered.mediaSources
        reread.report.items += gathered.report.items(in: .missingMedia)
        reread.conformToMedia = nil
        return reread
    }
}
