import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

/// Reads a timeline from a DaVinci Resolve project exported as a `.drp`.
///
/// The format is Blackmagic's own and undocumented. What's read here is
/// what independent open-source readers have measured on real exports and
/// agree on (see the findings on issue #36), and nothing more:
///
/// - The file is a ZIP archive of XML dumps of Resolve's project database:
///   `project.xml` (an `SM_Project`), the media pool's bins as
///   `MediaPool/…/MpFolder.xml` and each timeline's tracks as
///   `SeqContainer/<id>.xml`. Each XML file starts with a comment giving the
///   Resolve version and the project schema version (`DbPrjVer`).
/// - A timeline is a media pool clip (`Sm2MpTimelineClip`) holding its
///   `Sm2Sequence`, with the frame rate, resolution and start as binary
///   values. Its tracks (`Sm2TiTrack`) are in a sequence container, and
///   name the sequence they belong to.
/// - Clips on tracks give where they are and how long they are in whole
///   frames of the timeline (counted from 00:00:00:00, so a timeline at
///   01:00:00:00 starts at frame 86400 at 24 fps), their source in point in
///   frames, and the media pool clip they're of.
/// - Timeline markers are a binary value in `project.xml`, owned by the
///   timeline's sequence.
///
/// Clip settings are in each clip's `EffectFiltersBA`, a filter for each
/// Inspector group and effect. Zoom, position, opacity, composite mode,
/// volume and fades are read, and anything else that's set is reported
/// (see `ResolveClipSettings`). Grades and Fusion compositions are reported
/// too, and kept on their clips turned off.
struct DRPImporter {
    /// The project schema versions the layout has been checked against real
    /// exports of: 11 and 13 (Resolve 18.0 to 18.5, Blackmagic's training
    /// projects), 14 (Resolve 19.1), 15 (Resolve 20) and 17 (Resolve 21).
    /// Others are refused, pointing to FCPXML, until real exports of them
    /// have been tried. Resolve 17 (10) keeps clip settings in another
    /// layout.
    static let knownProjectVersions: Set<Int> = [11, 13, 14, 15, 17]

    private let archive: ZipArchive
    private let baseURL: URL?
    private var media = ImportedMedia()
    private var assembler = TimelineAssembler()
    private var report = ImportReport(format: .drp)
    private var settings = ProjectSettings()
    private var markers: [Marker] = []

    private var pool: [String: PoolItem] = [:]
    /// Each sequence's tracks, by the sequence's ID.
    private var tracks: [String: [ResolveTrack]] = [:]
    private var sequences: [String: MarkupElement] = [:]
    /// The lockable blobs in `project.xml` that hold markers, by owner.
    private var markerBlobs: [String: String] = [:]
    /// Audio clips made part of a picture's clip, by ID.
    private var mergedAudio: Set<String> = []
    private var reportedMulticam = false

    static func read(_ data: Data, baseURL: URL?) throws -> ImportedProject {
        let archive: ZipArchive
        do {
            archive = try ZipArchive(data: data)
        } catch {
            throw ResolveProjectError.damaged
        }
        var importer = DRPImporter(archive: archive, baseURL: baseURL)
        return try importer.run()
    }

    private init(archive: ZipArchive, baseURL: URL?) {
        self.archive = archive
        self.baseURL = baseURL
    }

    /// Whether data is a ZIP archive laid out as a Resolve project or
    /// timeline export is, with a `project.xml` at its root beside the
    /// media pool or timelines.
    static func isResolveArchive(_ data: Data) -> Bool {
        guard ZipArchive.hasSignature(data), let archive = try? ZipArchive(data: data) else { return false }
        return archive.entry(at: "project.xml") != nil
            && archive.entries.contains { $0.path.hasPrefix("SeqContainer") || $0.path.hasPrefix("MediaPool/") }
    }

    // MARK: - Version

    /// The Resolve version and project schema version an XML file in the
    /// archive says it was written with, from the comment after its
    /// declaration: `<!--DbAppVer="19.1.4.0011" DbPrjVer="14"-->`.
    static func version(of xml: Data) -> (app: String?, project: Int?) {
        let head = String(decoding: xml.prefix(2048), as: UTF8.self)
        func value(_ name: String) -> String? {
            guard let start = head.range(of: name + "=\"")?.upperBound,
                  let end = head[start...].firstIndex(of: "\"") else { return nil }
            return String(head[start..<end])
        }
        return (value("DbAppVer"), value("DbPrjVer").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }

    /// Larger than any project's XML; refused beyond it, so a small archive
    /// can't expand to fill memory.
    static let maximumEntrySize = 512 * 1024 * 1024

    /// An entry's contents; nil if there's no such entry.
    private func contents(of path: String) throws -> Data? {
        guard let entry = archive.entry(at: path) else { return nil }
        do {
            return try archive.data(for: entry, limit: Self.maximumEntrySize)
        } catch {
            throw ResolveProjectError.damaged
        }
    }

    private func xml(_ path: String) throws -> MarkupElement {
        do {
            return try MarkupElement.parse(try contents(of: path) ?? Data())
        } catch {
            throw ResolveProjectError.damaged
        }
    }

    // MARK: - Reading

    private mutating func run() throws -> ImportedProject {
        guard let projectData = try contents(of: "project.xml") else { throw ResolveProjectError.notAProject }
        // The version comes first, from the header comment: older versions
        // may write XML that doesn't parse, such as Resolve 17's element
        // names with "::" in them.
        let version = Self.version(of: projectData)
        if let schema = version.project, !Self.knownProjectVersions.contains(schema) {
            throw ResolveProjectError.unsupportedVersion(version.app ?? String(schema))
        }
        let project: MarkupElement
        do {
            project = try MarkupElement.parse(projectData)
        } catch {
            throw ResolveProjectError.damaged
        }
        guard project.name == "SM_Project" else { throw ResolveProjectError.notAProject }
        guard version.project != nil else {
            // Resolve 8 and older wrote the version on the root instead.
            throw ResolveProjectError.unsupportedVersion(version.app ?? project["DbAppVer"] ?? "")
        }

        // Markers are in the blobs of timelines and of clips on them; one
        // with an empty FieldsBlob, as real exports have, holds none.
        for element in project.allDescendants
        where element.name == "Sm2SequenceLockableBlob" || element.name == "Sm2TiItemLockableBlob" {
            if let owner = element.child("BlobOwner")?.text, !owner.isEmpty, let blob = element.child("FieldsBlob")?.text,
               !blob.isEmpty {
                markerBlobs[owner] = blob
            }
        }
        for entry in archive.entries where !entry.isDirectory {
            if entry.path.hasPrefix("MediaPool/") && entry.path.hasSuffix("MpFolder.xml") {
                readBin(try xml(entry.path))
            }
        }
        for entry in archive.entries where !entry.isDirectory {
            let components = entry.path.split(separator: "/")
            if components.contains(where: { $0.hasPrefix("SeqContainer") }) && entry.path.hasSuffix(".xml") {
                readContainer(try xml(entry.path))
            }
        }

        // The timeline that was open, or the first in the project's order.
        let order = (project.child("TimelineHandleVec")?.children("Element") ?? []).map(\.text)
        var timelines = pool.values.filter { $0.isTimeline && $0.sequenceID != nil }
        timelines.sort { a, b in
            let first = order.firstIndex(of: a.timelineID ?? "") ?? order.count
            let second = order.firstIndex(of: b.timelineID ?? "") ?? order.count
            return first != second ? first < second : a.name < b.name
        }
        let current = Int(project.child("CurrentTimelineIndex")?.text ?? "").flatMap { index in
            order.indices.contains(index) ? timelines.first { $0.timelineID == order[index] } : nil
        }
        guard let timeline = current ?? timelines.first, let sequenceID = timeline.sequenceID,
              !(tracks[sequenceID] ?? []).isEmpty else { throw InterchangeError.noTimeline }
        if timelines.count > 1 { report.add(.otherTimelines(count: timelines.count - 1)) }

        let sequence = sequences[sequenceID]
        let rate = sequence.flatMap(Self.frameRate)
        if rate == nil { report.add(.setting(name: "Frame rate")) }
        let frameDuration = Self.frameDuration(fps: rate ?? 24)
        settings.frameDuration = frameDuration
        if let size = sequence?.child("Resolution").flatMap({ ResolveBlobs.hex($0.text) }).flatMap(ResolveBlobs.resolution) {
            settings.renderSize = CGSize(width: size.width, height: size.height)
        }
        let start = startFrame(of: sequenceID, fps: rate ?? 24)
        let placement = Placement(base: .zero, origin: start, frameDuration: frameDuration, window: nil)
        importTracks(of: sequenceID, placement: placement, lane: 0, visiting: [sequenceID])
        importMarkers(of: sequenceID, frameDuration: frameDuration)

        var montage = Project(settings: settings, media: media.items)
        montage.tracks = assembler.tracks(report: &report)
        for marker in markers { montage.addMarker(at: marker.time, name: marker.name) }
        return ImportedProject(project: montage, report: report, name: timeline.name, mediaSources: media.sources)
    }

    // MARK: - Media pool

    /// A media pool clip: a file, or a timeline or compound clip holding a
    /// sequence of its own.
    private struct PoolItem {
        var id: String
        var element: String
        var name: String
        var path: String?
        var sequenceID: String?
        var timelineID: String?
        var frameRate: Double?
        var frameCount: Int64?
        var size: CGSize?
        var hasVideo = false
        var hasAudio = false

        var isTimeline: Bool { element == "Sm2MpTimelineClip" }
        var isNested: Bool { element == "Sm2MpTimelineClip" || element == "Sm2MpCompoundClip" }
    }

    /// The children of a vector, each written inside an `<Element>`.
    private static func elements(_ vector: MarkupElement) -> [MarkupElement] {
        vector.children.flatMap { $0.name == "Element" ? $0.children : [$0] }
    }

    private mutating func readBin(_ bin: MarkupElement) {
        guard bin.name == "Sm2MpFolder", let items = bin.child("MediaVec") else { return }
        for element in Self.elements(items) where element.name.hasPrefix("Sm2Mp") {
            guard let id = element["DbId"], pool[id] == nil else { continue }
            var item = PoolItem(id: id, element: element.name, name: element.child("Name")?.text ?? "")
            let timeline = element.descendant("TimelineSharedHandle", "Sm2Timeline")
            if let sequence = timeline?.descendant("Sequence", "Sm2Sequence") ?? element.descendant("Sequence", "Sm2Sequence"),
               let sequenceID = sequence["DbId"] {
                item.sequenceID = sequenceID
                sequences[sequenceID] = sequence
                item.timelineID = timeline?["DbId"]
                // The media pool's name is the one Resolve shows; the
                // timeline's own can be an older one, kept after a rename.
                if item.name.isEmpty, let name = timeline?.child("Name")?.text { item.name = name }
            }
            for info in Self.streams(of: element) {
                let isVideo = info.name == "BtVideoInfo"
                if isVideo { item.hasVideo = true } else { item.hasAudio = true }
                // The main stream's file: the picture's, or an audio clip's sound.
                if item.path == nil, isVideo || element.name == "Sm2MpAudioClip",
                   let clip = info.child("Clip").flatMap({ ResolveBlobs.hex($0.text) }) {
                    item.path = try? ResolveBlobs.mediaPath(fromClip: clip)
                }
                if isVideo {
                    readTime(of: info, into: &item)
                    if let geometry = info.child("Geometry").flatMap({ ResolveBlobs.hex($0.text) }),
                       let resolution = (try? ResolveBlobs.keyedDictionary(geometry))?.first(where: { $0.key == "Resolution" })?
                        .value.bytes.flatMap(ResolveBlobs.resolution) {
                        item.size = CGSize(width: resolution.width, height: resolution.height)
                    }
                }
            }
            pool[id] = item
        }
    }

    /// A clip's streams, not those of the timeline or sequence it holds.
    private static func streams(of element: MarkupElement) -> [MarkupElement] {
        element.children.flatMap { child -> [MarkupElement] in
            if child.name == "BtVideoInfo" || child.name == "BtAudioInfo" { return [child] }
            if child.name == "Sequence" || child.name == "TimelineSharedHandle" { return [] }
            return streams(of: child)
        }
    }

    private func readTime(of info: MarkupElement, into item: inout PoolItem) {
        guard let time = info.child("Time").flatMap({ ResolveBlobs.hex($0.text) }),
              let entries = try? ResolveBlobs.keyedDictionary(time) else { return }
        for (key, value) in entries {
            switch key {
            case "NumFrames": item.frameCount = value.integer
            case "FrameRate": item.frameRate = value.bytes.flatMap(ResolveBlobs.frameRate) ?? value.double
            default: break
            }
        }
    }

    // MARK: - Tracks

    private struct ResolveTrack {
        var kind: Kind
        var element: MarkupElement

        enum Kind { case video, audio, subtitle }
    }

    private mutating func readContainer(_ container: MarkupElement) {
        guard container.name == "Sm2SequenceContainer" else { return }
        for vector in container.children where vector.name.hasSuffix("TrackVec") {
            for track in Self.elements(vector) where track.name == "Sm2TiTrack" {
                let kind: ResolveTrack.Kind
                switch track.child("Type")?.text {
                case "0": kind = .video
                case "1": kind = .audio
                case "2": kind = .subtitle
                default:
                    if vector.name.hasPrefix("Video") {
                        kind = .video
                    } else if vector.name.hasPrefix("Audio") {
                        kind = .audio
                    } else if vector.name.hasPrefix("Subtitle") {
                        kind = .subtitle
                    } else {
                        continue
                    }
                }
                tracks[track.child("Sequence")?.text ?? "", default: []].append(ResolveTrack(kind: kind, element: track))
            }
        }
    }

    /// The timeline frame a sequence starts at, from its extents in
    /// seconds; or, failing that, its first clip's.
    private mutating func startFrame(of sequenceID: String, fps: Double) -> Int64 {
        if let extents = sequences[sequenceID]?.child("MediaExtents").flatMap({ ResolveBlobs.hex($0.text) })
            .flatMap(ResolveBlobs.extents) {
            return Int64((extents.start * fps).rounded())
        }
        let starts = (tracks[sequenceID] ?? []).flatMap { Self.items(of: $0.element) }
            .compactMap { ResolveBlobs.frames($0.child("Start")?.text)?.whole }
        if !starts.isEmpty { report.add(.setting(name: "Timeline start timecode")) }
        return starts.min() ?? 0
    }

    private static func items(of track: MarkupElement) -> [MarkupElement] {
        track.child("Items").map(elements) ?? []
    }

    /// Where a sequence's frames go on the timeline: frame `origin` at `base`.
    private struct Placement {
        var base: CMTime
        var origin: Int64
        var frameDuration: CMTime
        /// The part of the timeline a containing clip shows.
        var window: CMTimeRange?

        func time(_ frame: Int64) -> CMTime {
            base + duration(frame - origin)
        }

        func duration(_ frames: Int64) -> CMTime {
            InterchangeTime.frames(frames, frameDuration: frameDuration) ?? .zero
        }
    }

    /// A sequence's tracks, or for a multicam clip only the track of the
    /// angle it shows, of the kind of clip it is.
    private mutating func importTracks(
        of sequenceID: String, placement: Placement, lane: Int, visiting: Set<String>,
        angle: (kind: ResolveTrack.Kind, id: String)? = nil
    ) {
        var sequenceTracks = tracks[sequenceID] ?? []
        if let angle {
            sequenceTracks = sequenceTracks.filter { $0.kind == angle.kind && Self.angleID(of: $0.element) == angle.id }
        }
        // An angle's picture plays without its sound, which is an angle of its own.
        let audioItems = angle != nil ? [] : sequenceTracks.filter { $0.kind == .audio }.flatMap { Self.items(of: $0.element) }
        var videoIndex = 0, audioIndex = 0
        for track in sequenceTracks {
            let trackLane: Int
            switch track.kind {
            case .video:
                trackLane = lane + videoIndex
                videoIndex += 1
            case .audio:
                trackLane = lane - audioIndex
                audioIndex += 1
            case .subtitle:
                for item in Self.items(of: track.element) {
                    report.add(.caption, time: ResolveBlobs.frames(item.child("Start")?.text).map { placement.time($0.whole) })
                }
                continue
            }
            if let holder = track.element.child("FusionCompHolderItems"), !holder.children.isEmpty {
                report.add(.unsupportedEffect(name: "Fusion"))
            }
            for item in Self.items(of: track.element) {
                importItem(item, track: track.kind, lane: trackLane, placement: placement, audioItems: audioItems,
                           visiting: visiting)
            }
        }
    }

    // MARK: - Clips

    private mutating func importItem(
        _ item: MarkupElement, track: ResolveTrack.Kind, lane: Int, placement: Placement, audioItems: [MarkupElement],
        visiting: Set<String>
    ) {
        guard let start = ResolveBlobs.frames(item.child("Start")?.text)?.whole,
              let length = ResolveBlobs.frames(item.child("Duration")?.text)?.whole, length > 0 else { return }
        let timelineStart = placement.time(start)
        let duration = placement.duration(length)
        let prettyType = item.child("PrettyType")?.text ?? ""
        let poolItem = item.child("MediaRef").flatMap { pool[$0.text] }
        let name = [item.child("Name")?.text, poolItem?.name, prettyType].compactMap { $0 }.first { !$0.isEmpty }

        switch item.name {
        case "Sm2TiTransition":
            let range = CMTimeRange(start: timelineStart, duration: duration)
            assembler.addTransition(range, lane: lane)
            report.add(.transition(name: prettyType.isEmpty ? (name ?? "Transition") : prettyType), time: timelineStart)
            return
        case "Sm2TiGenerator":
            report.add(.generator(name: prettyType.isEmpty ? (name ?? "Generator") : prettyType), clipName: name, time: timelineStart)
            return
        case "Sm2TiVideoClip", "Sm2TiAudioClip":
            break
        default:
            report.add(.setting(name: item.name), clipName: name, time: timelineStart)
            return
        }
        if let id = item["DbId"], mergedAudio.contains(id) { return }
        if prettyType.localizedCaseInsensitiveContains("title") {
            report.add(.title, clipName: name, time: timelineStart)
            return
        }
        reportMarkers(on: item, clipName: name, at: timelineStart)

        let inPoint = ResolveBlobs.frames(item.child("In")?.text)?.whole
        let clipRange = CMTimeRange(start: timelineStart, duration: duration)
        let window = placement.window.map { $0.intersection(clipRange) } ?? clipRange

        // A compound clip or a timeline in this one: the clips inside it.
        if let poolItem, poolItem.isNested, let inner = poolItem.sequenceID {
            guard !visiting.contains(inner), visiting.count < 32 else { return }
            let rate = sequences[inner].flatMap(Self.frameRate)
            let innerStart = poolItem.isTimeline ? startFrame(of: inner, fps: rate ?? 24) : 0
            let nested = Placement(
                base: timelineStart, origin: innerStart + (inPoint ?? 0),
                frameDuration: rate.map(Self.frameDuration) ?? placement.frameDuration, window: window
            )
            importTracks(of: inner, placement: nested, lane: lane, visiting: visiting.union([inner]))
            if Self.hasSettings(item, isVideo: track == .video, frameDuration: placement.frameDuration) { report.add(.nestedSettings, clipName: name, time: timelineStart) }
            return
        }
        if poolItem?.element == "Sm2MpMulticamClip" {
            // The angle it shows, named in its FieldsBlob as the angle's track
            // names it in the multicam clip's own sequence.
            if let poolItem, let inner = poolItem.sequenceID, !visiting.contains(inner), track != .subtitle,
               let angle = item.child("FieldsBlob").flatMap({ ResolveBlobs.hex($0.text) }).flatMap(ResolveBlobs.multicamAngle(fromFieldsBlob:)),
               (tracks[inner] ?? []).contains(where: { $0.kind == track && Self.angleID(of: $0.element) == angle }) {
                let rate = sequences[inner].flatMap(Self.frameRate)
                let nested = Placement(
                    base: timelineStart, origin: startFrame(of: inner, fps: rate ?? 24) + (inPoint ?? 0),
                    frameDuration: rate.map(Self.frameDuration) ?? placement.frameDuration, window: window
                )
                importTracks(of: inner, placement: nested, lane: lane, visiting: visiting.union([inner]), angle: (track, angle))
                if !reportedMulticam {
                    report.add(.setting(name: "Multicam angles other than the one each clip shows"))
                    reportedMulticam = true
                }
                if Self.hasSettings(item, isVideo: track == .video, frameDuration: placement.frameDuration) { report.add(.nestedSettings, clipName: name, time: timelineStart) }
            } else {
                report.add(.setting(name: "Multicam clip"), clipName: name, time: timelineStart)
            }
            return
        }

        let mediaItem = mediaItem(for: item, poolItem: poolItem)
        // An empty in point is the start of the media: real exports leave it
        // empty on clips that play their media from the start, video and
        // audio alike, and write it on those that don't.
        var clip = Clip(
            content: mediaItem.content,
            sourceRange: CMTimeRange(start: mediaItem.kind == .image ? .zero : placement.duration(inPoint ?? 0), duration: duration),
            timelineStart: timelineStart
        )
        if mediaItem.kind != .image, let timeMap = item.child("MediaTimemapBA").flatMap({ ResolveBlobs.hex($0.text) }),
           timeMap.starts(with: [0, 0, 0, 1]) {
            // A retimed clip's map; a clip at its own speed has a short one.
            // Stills always have the long one, holding their one frame.
            report.add(.speedChange, clipName: name, time: timelineStart)
        }

        var linkedAudio: MarkupElement?
        if track == .video, mediaItem.kind != .audio {
            // Its own sound, linked to it in step on an audio track.
            let inStep = audioItems.filter { audio in
                audio.child("MediaRef")?.text == item.child("MediaRef")?.text
                    && audio.child("Start")?.text == item.child("Start")?.text
                    && audio.child("Duration")?.text == item.child("Duration")?.text
                    && !mergedAudio.contains(audio["DbId"] ?? "")
            }
            if let first = inStep.first, let id = first["DbId"] {
                mergedAudio.insert(id)
                linkedAudio = first
            } else if mediaItem.metadata.hasAudio {
                clip.isAudioDetached = true
            }
        }
        applySettings(
            of: item, linkedAudio: linkedAudio, to: &clip, isVideo: track == .video, clipName: name ?? mediaItem.name,
            frameDuration: placement.frameDuration
        )

        if let trimmed = clip.trimmed(to: window) {
            assembler.add(trimmed, kind: mediaItem.kind == .audio || track == .audio ? .audio : .video, lane: lane,
                          name: name ?? mediaItem.name)
        }
    }

    /// A clip's settings and effects, with those of the sound linked to it
    /// when that's part of the same clip. Effects, grades and Fusion
    /// compositions are kept turned off so the report can list them.
    private mutating func applySettings(
        of item: MarkupElement, linkedAudio: MarkupElement?, to clip: inout Clip, isVideo: Bool, clipName: String,
        frameDuration: CMTime
    ) {
        var kept: [(identifier: String, name: String, isVideo: Bool)] = []
        for (element, elementIsVideo) in [(item, isVideo)] + [linkedAudio].compactMap({ $0.map { ($0, false) } }) {
            guard let text = element.child("EffectFiltersBA")?.text, !text.isEmpty else { continue }
            guard let data = ResolveBlobs.hex(text), let filters = try? ResolveBlobs.filters(data) else {
                kept.append(("EffectFiltersBA", "Resolve effects", elementIsVideo))
                continue
            }
            let inPoint = ResolveBlobs.frames(element.child("In")?.text)?.whole ?? 0
            let notes = ResolveClipSettings.apply(
                filters, to: &clip, isVideo: elementIsVideo, inPoint: inPoint, frameDuration: frameDuration
            )
            for note in notes {
                switch note {
                case .setting(let name): report.add(.setting(name: name), clipName: clipName, time: clip.timelineStart)
                case .uneven(let name): report.add(.uneven(name: name), clipName: clipName, time: clip.timelineStart)
                case .effect(let identifier, let name): kept.append((identifier, name, elementIsVideo))
                }
            }
        }
        if isVideo, item.allDescendants.contains(where: { $0.name == "HasCorrection" && $0.text == "true" }) {
            kept.append(("pLmVerTable", "Color grade", true))
        }
        if isVideo, let composition = item.child("CompositionTable"), !composition.children.isEmpty {
            kept.append(("CompositionTable", "Fusion", true))
        }
        for effect in kept {
            report.add(.unsupportedEffect(name: effect.name), clipName: clipName, time: clip.timelineStart)
            clip.effects.append(Effect(isEnabled: false, .unsupported(UnsupportedEffect(
                format: InterchangeFormat.drp.rawValue, identifier: effect.identifier, name: effect.name,
                isVideo: effect.isVideo, parameters: [], original: nil
            ))))
        }
    }

    /// The angle a track of a multicam clip's sequence holds.
    private static func angleID(of track: MarkupElement) -> String? {
        track.child("FieldsBlob").flatMap { ResolveBlobs.hex($0.text) }.flatMap(ResolveBlobs.angleID(fromTrackFieldsBlob:))
    }

    /// Whether a clip has any Inspector setting or effect, which a compound
    /// clip's flattened contents don't take on: one that would change a
    /// plain clip or be reported on it, so not those set as Montage has them.
    private static func hasSettings(_ item: MarkupElement, isVideo: Bool, frameDuration: CMTime) -> Bool {
        guard let text = item.child("EffectFiltersBA")?.text, !text.isEmpty else { return false }
        guard let data = ResolveBlobs.hex(text), let filters = try? ResolveBlobs.filters(data) else { return true }
        let plain = Clip(mediaID: UUID(), sourceRange: CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)))
        var clip = plain
        let notes = ResolveClipSettings.apply(filters, to: &clip, isVideo: isVideo, inPoint: 0, frameDuration: frameDuration)
        return !notes.isEmpty || clip != plain
    }

    // MARK: - Media

    private mutating func mediaItem(for item: MarkupElement, poolItem: PoolItem?) -> MediaItem {
        let timelinePath = item.child("MediaFilePath")?.text
        let path = poolItem?.path ?? (timelinePath?.isEmpty == false ? timelinePath : nil)
        let url = path.flatMap(fileURL)
        let fallbackName = poolItem?.name ?? item.child("Name")?.text ?? "Media"
        let name = url?.lastPathComponent ?? fallbackName
        let fileType = UTType(filenameExtension: (name as NSString).pathExtension)

        let kind: MediaItem.Kind
        if poolItem?.element == "Sm2MpStillClip" || fileType?.conforms(to: .image) == true {
            kind = .image
        } else if poolItem?.element == "Sm2MpAudioClip" || (poolItem.map { !$0.hasVideo && $0.hasAudio } ?? false)
            || (poolItem == nil && item.name == "Sm2TiAudioClip") || fileType?.conforms(to: .audio) == true {
            kind = .audio
        } else {
            kind = .video
        }

        var metadata = MediaMetadata()
        if kind != .image, let frames = poolItem?.frameCount, let rate = poolItem?.frameRate, rate > 0 {
            metadata.duration = InterchangeTime.frames(frames, frameDuration: Self.frameDuration(fps: rate)) ?? .zero
            if kind == .video { metadata.nominalFrameRate = rate }
        }
        if let size = poolItem?.size, kind != .audio { metadata.naturalSize = size }
        if kind == .audio || (kind == .video && poolItem?.hasAudio ?? true) {
            metadata.audioChannelCount = 2
            metadata.audioSampleRate = 48000
        }
        return media.item(key: poolItem?.id ?? path ?? name, url: url, name: name, kind: kind, metadata: metadata)
    }

    /// A path as Resolve wrote it, on a Mac or Linux or as "D:\Footage\…" on
    /// Windows, as a file URL; a Windows path keeps its name to look for.
    private func fileURL(_ path: String) -> URL? {
        let isWindows = path.contains("\\") || (path.count > 1 && path.dropFirst().first == ":")
        if isWindows {
            let parts = path.split(whereSeparator: { $0 == "\\" || $0 == "/" })
            return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
        }
        return ImportedMedia.url(from: path, relativeTo: baseURL)
    }

    // MARK: - Markers

    /// The timeline's markers, counted in frames from its start, as the
    /// project's markers.
    private mutating func importMarkers(of sequenceID: String, frameDuration: CMTime) {
        guard let blob = markerBlobs[sequenceID], let data = ResolveBlobs.hex(blob) else { return }
        do {
            for marker in try ResolveBlobs.markers(fromFieldsBlob: data) {
                guard let time = InterchangeTime.frames(marker.frame, frameDuration: frameDuration) else { continue }
                markers.append(Marker(time: time, name: marker.name.isEmpty ? marker.note : marker.name))
            }
        } catch {
            report.add(.marker(name: ""))
        }
    }

    /// A clip's own markers, which Montage has no place for. Where on the
    /// clip they are hasn't been worked out, so they're listed by clip.
    private mutating func reportMarkers(on item: MarkupElement, clipName: String?, at time: CMTime) {
        if let id = item["DbId"], let blob = markerBlobs[id], let data = ResolveBlobs.hex(blob),
           let clipMarkers = try? ResolveBlobs.markers(fromFieldsBlob: data) {
            for marker in clipMarkers {
                report.add(.marker(name: marker.name.isEmpty ? marker.note : marker.name), clipName: clipName, time: time)
            }
        } else if !(item.child("MarkersBA")?.text ?? "").isEmpty {
            report.add(.marker(name: ""), clipName: clipName, time: time)
        }
    }

    // MARK: - Times

    private static func frameRate(of sequence: MarkupElement) -> Double? {
        sequence.child("FrameRate").flatMap { ResolveBlobs.hex($0.text) }.flatMap(ResolveBlobs.frameRate)
    }

    /// The length of a frame at a rate given in frames a second: exact for
    /// the NTSC rates, which are written as 23.976 and the like.
    static func frameDuration(fps: Double) -> CMTime {
        guard fps.isFinite, fps > 0 else { return CMTime(value: 1, timescale: 24) }
        let whole = fps.rounded()
        if abs(fps - whole) < 0.0005 { return CMTime(value: 1, timescale: CMTimeScale(max(1, whole))) }
        let ntsc = (fps * 1.001).rounded()
        if abs(fps * 1.001 - ntsc) < 0.005 { return InterchangeTime.time(1001, over: Int64(ntsc) * 1000) }
        return CMTime(value: Int64((1_000_000 / fps).rounded()), timescale: 1_000_000)
    }
}

/// Why a DaVinci Resolve project couldn't be read.
public enum ResolveProjectError: LocalizedError, Equatable {
    /// The archive or the XML in it is damaged.
    case damaged
    /// A ZIP archive, but not of a Resolve project.
    case notAProject
    /// From a version of Resolve whose projects haven't been tried, by its
    /// version number.
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .damaged:
            String(localized: "DRP.Error.Damaged", bundle: #bundle)
        case .notAProject:
            String(localized: "DRP.Error.NotAProject", bundle: #bundle)
        case .unsupportedVersion(let version) where version.isEmpty:
            String(localized: "DRP.Error.UnknownVersion", bundle: #bundle)
        case .unsupportedVersion(let version):
            String(format: String(localized: "DRP.Error.UnsupportedVersion", bundle: #bundle), version)
        }
    }

    public var recoverySuggestion: String? {
        String(localized: "DRP.Error.ExportFCPXML", bundle: #bundle)
    }
}
