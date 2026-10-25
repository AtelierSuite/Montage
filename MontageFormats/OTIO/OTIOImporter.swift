import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

/// Reads a timeline from an OpenTimelineIO file (`.otio`), the JSON that
/// OTIO itself, DaVinci Resolve, Premiere Pro, Avid Media Composer, Nuke
/// Studio and others write.
///
/// A timeline holds a stack of tracks, bottom first, each a sequence of
/// clips, gaps and transitions. That's Montage's own shape, so tracks come
/// across as they are: video tracks in order, then audio tracks. A stack or
/// track nested inside a track, which Montage has no place for, is flattened
/// into the tracks around it, trimmed to its range. Transitions don't take
/// time of their own in OTIO, so leaving one out leaves the cut it was over.
///
/// As with Final Cut 7 XML, a clip's picture and sound are separate clips on
/// video and audio tracks. Where the sound is in step with the picture
/// they're made one clip, and otherwise the picture's clip has its audio
/// detached.
///
/// A file Montage wrote keeps each clip's own settings in its metadata, so
/// they come back as they were.
struct OTIOImporter {
    typealias Object = [String: Any]

    private let baseURL: URL?
    private var media = ImportedMedia()
    private var report = ImportReport(format: .otio)
    private var settings = ProjectSettings()
    private var markers: [(time: CMTime, name: String)] = []
    private var placed: [PlacedClip] = []

    /// A clip read from the file, before it's put on a track.
    private struct PlacedClip {
        var clip: Clip
        var kind: Track.Kind
        var lane: Int
        var name: String
        /// On a track turned off in the other app.
        var isOnDisabledTrack: Bool
        /// Whether Montage wrote the clip's own settings into the file.
        var hasMontageSettings: Bool
        /// The sound of a video clip, which Montage wrote beside it.
        var isMontageCompanion: Bool
    }

    /// Where an item's own time falls on the timeline.
    private struct Placement {
        /// The timeline time of `origin`, a time in the item.
        var base: CMTime
        var origin: CMTime
        /// The part of the timeline the item shows, past which its contents
        /// are trimmed.
        var window: CMTimeRange
        var kind: Track.Kind
        var lane: Int
        var isDisabled: Bool

        func timeline(_ time: CMTime) -> CMTime { base + (time - origin) }

        /// The placement of an item inside this one, which starts at
        /// `start` of this one's time and shows `range` of its own.
        func nested(at start: CMTime, showing range: CMTimeRange) -> Placement {
            var placement = self
            placement.base = timeline(start)
            placement.origin = range.start
            placement.window = window.intersection(CMTimeRange(start: placement.base, duration: range.duration))
            return placement
        }
    }

    // MARK: - Reading

    /// Whether data looks like JSON rather than XML: an OTIO file is an
    /// object.
    static func isJSON(_ data: Data) -> Bool {
        let start = data.prefix(64).drop { [0x20, 0x09, 0x0A, 0x0D, 0xEF, 0xBB, 0xBF].contains($0) }
        return start.first == UInt8(ascii: "{")
    }

    static func read(_ data: Data, baseURL: URL?) throws -> ImportedProject {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            // Python's writer puts NaN and Infinity in, which JSON5 allows.
            do {
                object = try JSONSerialization.jsonObject(with: data, options: .json5Allowed)
            } catch {
                let reason = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                throw InterchangeError.unreadable(reason)
            }
        }
        guard let root = object as? Object, schema(of: root) != nil else { throw InterchangeError.unsupportedFormat }
        var importer = OTIOImporter(baseURL: baseURL)
        return try importer.run(root)
    }

    private init(baseURL: URL?) {
        self.baseURL = baseURL
    }

    private mutating func run(_ root: Object) throws -> ImportedProject {
        let timelines = Self.timelines(in: root)
        guard let timeline = timelines.first else { throw InterchangeError.noTimeline }
        if timelines.count > 1 { report.add(.otherTimelines(count: timelines.count - 1)) }

        // A bare stack or track is a timeline without the wrapper.
        let stack: Object
        switch Self.schema(of: timeline)?.name {
        case "Timeline": stack = timeline["tracks"] as? Object ?? [:]
        case "Track": stack = ["OTIO_SCHEMA": "Stack.1", "children": [timeline]]
        default: stack = timeline
        }

        let montage = (timeline["metadata"] as? Object)?[OTIOJSON.montageKey] as? Object
        settings.frameDuration = Self.frameDuration(of: timeline, stack: stack)
        if let width = (montage?["width"] as? NSNumber)?.doubleValue, let height = (montage?["height"] as? NSNumber)?.doubleValue,
           width > 0, height > 0 {
            settings.renderSize = CGSize(width: width, height: height)
        }

        let length = Self.duration(of: stack)
        let range = OTIOTime.range(stack["source_range"]) ?? CMTimeRange(start: .zero, duration: length)
        let top = Placement(base: .zero, origin: range.start, window: CMTimeRange(start: .zero, duration: range.duration),
                            kind: .video, lane: 0, isDisabled: false)
        importStack(stack, placement: top, isTop: true)

        var project = Project(settings: settings, media: media.items)
        project.tracks = assembleTracks()
        for marker in markers.sorted(by: { $0.time < $1.time }) {
            project.addMarker(at: marker.time, name: marker.name)
        }
        // Resolve and Kdenlive leave the name empty; the file's is used then.
        let name = (timeline["name"] as? String).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return ImportedProject(project: project, report: report, name: name, mediaSources: media.sources)
    }

    /// The timelines in a file: itself, or those in a collection.
    private static func timelines(in object: Object) -> [Object] {
        switch schema(of: object)?.name {
        case "Timeline", "Stack", "Track":
            return [object]
        case "SerializableCollection":
            return (object["children"] as? [Any] ?? []).compactMap { $0 as? Object }.flatMap(timelines(in:))
        default:
            return []
        }
    }

    /// The timeline's frame rate: its start time's, or else its first clip's.
    private static func frameDuration(of timeline: Object, stack: Object) -> CMTime {
        if let rate = OTIOTime.rate(of: timeline["global_start_time"]), let frame = OTIOTime.frameDuration(rate: rate) {
            return frame
        }
        var pending: [Object] = [stack]
        while !pending.isEmpty {
            let item = pending.removeFirst()
            if schema(of: item)?.name == "Clip", let rate = OTIOTime.rate(of: (item["source_range"] as? Object)?["duration"]),
               let frame = OTIOTime.frameDuration(rate: rate) {
                return frame
            }
            pending += (item["children"] as? [Any] ?? []).compactMap { $0 as? Object }
        }
        return ProjectSettings().frameDuration
    }

    // MARK: - Compositions

    /// A stack's children, layered: tracks, and anything else, each on a
    /// lane of its own from the stack's.
    private mutating func importStack(_ stack: Object, placement: Placement, isTop: Bool) {
        importMarkers(of: stack, placement: placement)
        importCompositionEffects(of: stack, at: placement.window.start)
        var videoCount = 0
        var audioCount = 0
        for (index, child) in Self.children(of: stack).enumerated() {
            var inner = placement
            if Self.schema(of: child)?.name == "Track" {
                inner.kind = Self.kind(of: child) ?? placement.kind
            }
            if isTop {
                // The top stack's tracks count up from the bottom by kind.
                inner.lane = inner.kind == .video ? videoCount : -audioCount
            } else {
                inner.lane = placement.lane + (inner.kind == .video ? index : -index)
            }
            if inner.kind == .video { videoCount += 1 } else { audioCount += 1 }
            let range = OTIOTime.range(child["source_range"]) ?? CMTimeRange(start: .zero, duration: Self.duration(of: child))
            importItem(child, at: placement.origin, range: range, placement: inner)
        }
    }

    /// A track's children, one after another. Transitions sit between them
    /// without taking time.
    private mutating func importTrack(_ track: Object, placement: Placement) {
        var placement = placement
        if (track["enabled"] as? Bool) == false { placement.isDisabled = true }
        importMarkers(of: track, placement: placement)
        importCompositionEffects(of: track, at: placement.window.start)
        var cursor = CMTime.zero
        for child in Self.children(of: track) {
            let schema = Self.schema(of: child)?.name
            if schema == "Transition" {
                let name = (child["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? child["transition_type"] as? String ?? "Transition"
                report.add(.transition(name: name), time: placement.timeline(cursor))
                continue
            }
            let range = OTIOTime.range(child["source_range"]) ?? CMTimeRange(start: .zero, duration: Self.duration(of: child))
            guard range.duration > .zero else { continue }
            importItem(child, at: cursor, range: range, placement: placement)
            cursor = cursor + range.duration
        }
    }

    /// An item of a track or stack, starting at `start` in its parent's
    /// time and showing `range` of its own.
    private mutating func importItem(_ item: Object, at start: CMTime, range: CMTimeRange, placement: Placement) {
        let inner = placement.nested(at: start, showing: range)
        let name = item["name"] as? String
        let schema = Self.schema(of: item)?.name
        if (item["enabled"] as? Bool) == false, schema != "Track", schema != "Gap" {
            report.add(.disabledClip, clipName: name, time: inner.base)
            return
        }
        switch schema {
        case "Gap":
            break
        case "Clip":
            guard inner.window.duration > .zero else { return }
            importClip(item, range: range, placement: inner)
        case "Track":
            importTrack(item, placement: inner)
        case "Stack":
            importStack(item, placement: inner, isTop: false)
        default:
            report.add(.setting(name: schema ?? "Item"), clipName: name, time: inner.base)
        }
    }

    private mutating func importMarkers(of item: Object, placement: Placement) {
        for marker in (item["markers"] as? [Any] ?? []).compactMap({ $0 as? Object }) {
            guard let range = OTIOTime.range(marker["marked_range"]) else { continue }
            let time = placement.timeline(range.start)
            // Those on trimmed-off parts aren't seen in the other app either.
            guard time >= placement.window.start, time <= placement.window.end else { continue }
            markers.append((time, marker["name"] as? String ?? ""))
        }
    }

    // MARK: - Clips

    /// A clip, showing `range` of its media's time.
    private mutating func importClip(_ item: Object, range: CMTimeRange, placement: Placement) {
        let clipName = item["name"] as? String
        let timelineStart = placement.base
        let reference = Self.mediaReference(of: item)
        let referenceSchema = reference.flatMap { Self.schema(of: $0)?.name }
        let saved = Self.montageClip(in: item)

        var content: ClipContent
        var mediaStart = range.start
        switch referenceSchema {
        case "ExternalReference", "MissingReference", nil:
            let mediaItem = mediaItem(for: reference, clipName: clipName, kind: placement.kind)
            content = mediaItem.content
            if let available = OTIOTime.range(reference?["available_range"]) { mediaStart = range.start - available.start }
            if mediaItem.kind == .image || mediaStart < .zero { mediaStart = .zero }
        case "GeneratorReference" where saved?.content.isGenerated == true:
            // Montage's text and shapes, which it writes as generators.
            content = saved!.content
            mediaStart = .zero
        case "GeneratorReference":
            let kind = reference?["generator_kind"] as? String ?? reference?["name"] as? String ?? clipName ?? ""
            report.add(.generator(name: kind), clipName: clipName, time: timelineStart)
            return
        case "ImageSequenceReference":
            report.add(.setting(name: "Image sequence"), clipName: clipName, time: timelineStart)
            return
        default:
            report.add(.setting(name: referenceSchema ?? "Media"), clipName: clipName, time: timelineStart)
            return
        }

        var clip = saved ?? Clip(content: content, sourceRange: range)
        clip.id = UUID()
        clip.content = content
        clip.sourceRange = CMTimeRange(start: mediaStart, duration: range.duration)
        clip.timelineStart = timelineStart
        if saved == nil {
            importEffects(of: item, to: &clip, isVideo: placement.kind == .video, clipName: clipName)
        }
        importMarkers(of: item, placement: placement)

        guard let trimmed = clip.trimmed(to: placement.window) else { return }
        let mediaKind = media.items.first { $0.id == clip.mediaID }?.kind
        let montage = item["metadata"] as? Object
        placed.append(PlacedClip(
            clip: trimmed, kind: mediaKind == .audio ? .audio : placement.kind, lane: placement.lane,
            name: clipName ?? media.items.first { $0.id == clip.mediaID }?.name ?? "",
            isOnDisabledTrack: placement.isDisabled, hasMontageSettings: saved != nil,
            isMontageCompanion: ((montage?[OTIOJSON.montageKey] as? Object)?["companion"] as? Bool) ?? false
        ))
    }

    /// OTIO's effects have no parameters of their own, only a name and
    /// metadata, so only those whose metadata says what they do map onto
    /// Montage's: the clip settings Resolve writes as effects, and
    /// Kdenlive's fades. Changes of speed are reported, and anything else
    /// is kept on the clip, turned off.
    private mutating func importEffects(of item: Object, to clip: inout Clip, isVideo: Bool, clipName: String?) {
        for effect in (item["effects"] as? [Any] ?? []).compactMap({ $0 as? Object }) {
            switch Self.schema(of: effect)?.name {
            case "LinearTimeWarp":
                let scalar = (effect["time_scalar"] as? NSNumber)?.doubleValue ?? 1
                if abs(scalar - 1) > 0.000_001 { report.add(.speedChange, clipName: clipName, time: clip.timelineStart) }
            case "FreezeFrame", "TimeEffect":
                report.add(.speedChange, clipName: clipName, time: clip.timelineStart)
            default:
                if let block = Self.resolveBlock(effect) {
                    applyResolveBlock(block, to: &clip, clipName: clipName)
                    continue
                }
                if applyKdenliveFade(effect, to: &clip) { continue }
                let name = Self.effectName(effect)
                report.add(.unsupportedEffect(name: name), clipName: clipName, time: clip.timelineStart)
                let parameters = ((effect["metadata"] as? Object) ?? [:]).keys.sorted().map { key in
                    UnsupportedEffect.Parameter(name: key, key: key, value: Self.text(of: (effect["metadata"] as? Object)?[key]))
                }
                clip.effects.append(Effect(isEnabled: false, .unsupported(UnsupportedEffect(
                    format: InterchangeFormat.otio.rawValue, identifier: effect["effect_name"] as? String ?? name, name: name,
                    isVideo: isVideo, parameters: parameters, original: Self.text(of: effect)
                ))))
            }
        }
    }

    /// Effects on a track or stack, which Montage has no place for. Resolve's
    /// blocks of settings left as they were are no loss.
    private mutating func importCompositionEffects(of composition: Object, at time: CMTime) {
        for effect in (composition["effects"] as? [Any] ?? []).compactMap({ $0 as? Object }) {
            if let block = Self.resolveBlock(effect), Self.isNeutral(block) { continue }
            report.add(.unsupportedEffect(name: Self.effectName(effect)), clipName: composition["name"] as? String, time: time)
        }
    }

    // MARK: - Resolve

    /// Resolve writes every block of its inspector (Transform, Cropping,
    /// Composite, Retime and Scaling, Fairlight's volume and EQ, …) onto
    /// each clip as an effect named "Resolve Effect", with the block in its
    /// metadata: what it is, whether it's on, and each parameter beside its
    /// default.
    private static func resolveBlock(_ effect: Object) -> Object? {
        guard let block = (effect["metadata"] as? Object)?["Resolve_OTIO"] as? Object, block["Effect Name"] is String else {
            return nil
        }
        return block
    }

    private static func parameters(of block: Object) -> [Object] {
        (block["Parameters"] as? [Any] ?? []).compactMap { $0 as? Object }
    }

    /// Whether a block changes nothing: it's turned off, or every parameter
    /// is at its default throughout.
    private static func isNeutral(_ block: Object) -> Bool {
        (block["Enabled"] as? Bool) == false || parameters(of: block).allSatisfy(isDefault)
    }

    private static func isDefault(_ parameter: Object) -> Bool {
        guard let fallback = parameter["Default Parameter Value"] as? NSObject else { return false }
        let keyframes = (parameter["Key Frames"] as? Object ?? [:]).values.compactMap { ($0 as? Object)?["Value"] }
        let values: [Any?] = [parameter["Parameter Value"]] + keyframes
        return values.allSatisfy { value in
            guard let value = value as? NSObject else { return value == nil }
            return value.isEqual(fallback)
        }
    }

    /// Takes the settings a Resolve block changes into the clip's: zoom,
    /// rotation, opacity and clip volume. A block left as it was is no loss;
    /// one with changes that aren't brought in (pan and tilt, cropping), or
    /// that change over time, is reported under its own name, such as
    /// "Transform".
    ///
    /// Zoom is `transformationZoomX` and `transformationZoomY`, 1 for the
    /// picture fitted to the frame, as Montage's scale is. Rotation is
    /// `transformationRotationAngle`, in degrees counter-clockwise, which
    /// Montage turns the other way.
    private mutating func applyResolveBlock(_ block: Object, to clip: inout Clip, clipName: String?) {
        guard !Self.isNeutral(block) else { return }
        var leftOver = false
        var zoom: (x: Double?, y: Double?) = (nil, nil)
        var isZoomed = false
        for parameter in Self.parameters(of: block) {
            // Both zooms, as one alone may be changed.
            let id = (parameter["Parameter ID"] as? String ?? "").lowercased()
            guard id.hasPrefix("transformationzoom"), let value = (parameter["Parameter Value"] as? NSNumber)?.doubleValue else {
                continue
            }
            if id.hasSuffix("y") { zoom.y = value } else { zoom.x = value }
        }
        for parameter in Self.parameters(of: block) where !Self.isDefault(parameter) {
            let id = (parameter["Parameter ID"] as? String ?? "").lowercased()
            let value = (parameter["Parameter Value"] as? NSNumber)?.doubleValue
            let isAnimated = !((parameter["Key Frames"] as? Object) ?? [:]).isEmpty
            guard let value, !isAnimated, !id.contains("dynamic") else {
                leftOver = true
                continue
            }
            if id.hasPrefix("transformationzoom") {
                isZoomed = true
            } else if id == "transformationrotationangle" {
                clip.transform.rotation = Animatable(value == 0 ? 0 : -value)
            } else if id.contains("opacity") {
                clip.opacity = Animatable(max(0, min(1, value > 1 ? value / 100 : value)))
            } else if id.contains("volume") || id.contains("level") || id.hasSuffix("gain") {
                // Fairlight's levels are in decibels.
                clip.volume = Animatable(max(0, pow(10, value / 20)))
            } else {
                leftOver = true
            }
        }
        if isZoomed, let scale = zoom.x ?? zoom.y {
            clip.transform.scale = Animatable(scale)
            if let x = zoom.x, let y = zoom.y, abs(x - y) > 0.0001 {
                report.add(.uneven(name: "Zoom"), clipName: clipName, time: clip.timelineStart)
            }
        }
        if leftOver {
            report.add(.unsupportedEffect(name: block["Effect Name"] as? String ?? "Resolve Effect"), clipName: clipName,
                       time: clip.timelineStart)
        }
    }

    // MARK: - Kdenlive

    /// Kdenlive's fades, by how long they last: `fadein` and `fadeout` of
    /// the sound, and `fade_from_black` and `fade_to_black` of the picture,
    /// as keyframes of the clip's volume or opacity. Returns whether the
    /// effect was one.
    private func applyKdenliveFade(_ effect: Object, to clip: inout Clip) -> Bool {
        let kind = (effect["effect_name"] as? String ?? "").lowercased()
        guard ["fadein", "fadeout", "fade_from_black", "fade_to_black"].contains(kind),
              let length = OTIOTime.time((effect["metadata"] as? Object)?["duration"]) else { return false }
        let fade = min(InterchangeTime.conformed(max(length, .zero), to: settings.frameDuration), clip.duration)
        guard fade > .zero else { return true }
        let isIn = kind == "fadein" || kind == "fade_from_black"
        let keyframes = isIn
            ? [Keyframe(time: .zero, value: 0.0), Keyframe(time: fade, value: 1.0)]
            : [Keyframe(time: clip.duration - fade, value: 1.0), Keyframe(time: clip.duration, value: 0.0)]
        func faded(_ parameter: Animatable<Double>) -> Animatable<Double> {
            let level = parameter.value
            let kept = parameter.keyframes.filter { old in !keyframes.contains { $0.time == old.time } }
            let added = keyframes.map { Keyframe(time: $0.time, value: $0.value * level) }
            return Animatable(level, keyframes: (kept + added).sorted { $0.time < $1.time })
        }
        if kind.hasPrefix("fade_") { clip.opacity = faded(clip.opacity) } else { clip.volume = faded(clip.volume) }
        return true
    }

    // MARK: - Media

    /// The reference a clip plays: the active one of its references, or
    /// the one reference a clip written before OTIO 0.15 has.
    private static func mediaReference(of clip: Object) -> Object? {
        if let references = clip["media_references"] as? Object {
            let key = clip["active_media_reference_key"] as? String ?? "DEFAULT_MEDIA"
            return references[key] as? Object ?? references.keys.sorted().lazy.compactMap { references[$0] as? Object }.first
        }
        return clip["media_reference"] as? Object
    }

    private mutating func mediaItem(for reference: Object?, clipName: String?, kind trackKind: Track.Kind) -> MediaItem {
        let url = ImportedMedia.url(from: reference?["target_url"] as? String, relativeTo: baseURL)
        let referenceName = (reference?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let name = url?.lastPathComponent ?? referenceName ?? clipName ?? "Media"
        let fileType = url.flatMap { UTType(filenameExtension: $0.pathExtension) }
            ?? UTType(filenameExtension: (name as NSString).pathExtension)
        let kind: MediaItem.Kind = if fileType?.conforms(to: .image) == true {
            .image
        } else if fileType?.conforms(to: .audio) == true {
            .audio
        } else if fileType?.conforms(to: .movie) == true {
            .video
        } else {
            trackKind == .video ? .video : .audio
        }

        // What the file holds is read from it once it's found; until then,
        // what the other app said, and the project's shape.
        let available = OTIOTime.range(reference?["available_range"])
        var metadata = MediaMetadata(duration: kind == .image ? .zero : available?.duration ?? .zero)
        if kind != .audio { metadata.naturalSize = settings.renderSize }
        if kind == .video { metadata.nominalFrameRate = settings.frameRate }
        if kind != .image {
            metadata.audioChannelCount = 2
            metadata.audioSampleRate = 48000
        }
        return media.item(key: referenceName ?? name, url: url, name: name, kind: kind, metadata: metadata)
    }

    /// The clip as Montage saved it into the clip's metadata, if it did.
    private static func montageClip(in item: Object) -> Clip? {
        guard let saved = ((item["metadata"] as? Object)?[OTIOJSON.montageKey] as? Object)?["clip"],
              JSONSerialization.isValidJSONObject(saved),
              let data = try? JSONSerialization.data(withJSONObject: saved) else { return nil }
        return try? JSONDecoder().decode(Clip.self, from: data)
    }

    // MARK: - Tracks

    /// Puts the clips onto tracks. A picture and its sound in step are made
    /// one clip; a picture whose sound isn't there plays without it.
    private mutating func assembleTracks() -> [Track] {
        var consumed = Set<Int>()
        for index in placed.indices where placed[index].kind == .video {
            let picture = placed[index]
            guard media.items.first(where: { $0.id == picture.clip.mediaID })?.kind == .video else { continue }
            let match = placed.indices.first { other in
                let sound = placed[other]
                return !consumed.contains(other) && sound.kind == .audio && sound.clip.mediaID == picture.clip.mediaID
                    && sound.clip.timelineRange == picture.clip.timelineRange
                    && sound.clip.sourceRange == picture.clip.sourceRange
                    && sound.isOnDisabledTrack == picture.isOnDisabledTrack
                    // Montage's own sound clips stay as they are.
                    && (!picture.hasMontageSettings || sound.isMontageCompanion)
            }
            if let match {
                consumed.insert(match)
                if !picture.hasMontageSettings { placed[index].clip.isAudioDetached = false }
            } else if !picture.hasMontageSettings {
                placed[index].clip.isAudioDetached = true
            }
        }

        var assembler = TimelineAssembler()
        var disabled = Set<Clip.ID>()
        for (index, item) in placed.enumerated() where !consumed.contains(index) {
            assembler.add(item.clip, kind: item.kind, lane: item.lane, name: item.name)
            if item.isOnDisabledTrack { disabled.insert(item.clip.id) }
        }
        // Tracks turned off in the other app are hidden, or muted.
        return assembler.tracks(report: &report).map { track in
            var track = track
            if !track.clips.isEmpty, track.clips.allSatisfy({ disabled.contains($0.id) }) {
                if track.kind == .video { track.isHidden = true } else { track.isMuted = true }
            }
            return track
        }
    }

    // MARK: - Schema

    /// An object's schema, such as `Clip` and 2 for `Clip.2`.
    static func schema(of object: Object) -> (name: String, version: Int)? {
        guard let schema = object["OTIO_SCHEMA"] as? String else { return nil }
        let parts = schema.split(separator: ".", maxSplits: 1)
        return (String(parts.first ?? ""), parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
    }

    private static func children(of composition: Object) -> [Object] {
        (composition["children"] as? [Any] ?? []).compactMap { $0 as? Object }
    }

    private static func kind(of track: Object) -> Track.Kind? {
        switch (track["kind"] as? String)?.lowercased() {
        case "video": .video
        case "audio": .audio
        default: nil
        }
    }

    /// How long an item lasts when it has no range of its own: a clip for
    /// as long as its media, a track for all its items, a stack for its
    /// longest.
    private static func duration(of item: Object) -> CMTime {
        if let range = OTIOTime.range(item["source_range"]) { return range.duration }
        switch schema(of: item)?.name {
        case "Clip":
            return OTIOTime.range(mediaReference(of: item)?["available_range"])?.duration ?? .zero
        case "Track":
            return children(of: item).filter { schema(of: $0)?.name != "Transition" }.map(duration(of:)).reduce(.zero, +)
        case "Stack":
            return children(of: item).map(duration(of:)).max() ?? .zero
        case "Timeline":
            return (item["tracks"] as? Object).map(duration(of:)) ?? .zero
        default:
            return .zero
        }
    }

    private static func effectName(_ effect: Object) -> String {
        [effect["name"], effect["effect_name"]].compactMap { $0 as? String }.first { !$0.isEmpty }
            ?? schema(of: effect)?.name ?? "Effect"
    }

    /// A JSON value as text, for the report and to keep.
    private static func text(of value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "\(value)"
    }
}
