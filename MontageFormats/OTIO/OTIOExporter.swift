import CoreMedia
import Foundation
import MontageEngine

/// Writes a project as an OpenTimelineIO file (`.otio`), with the schema
/// versions OTIO 0.15 and later write (`Timeline.1`, `Track.1`, `Clip.2`),
/// which DaVinci Resolve, Premiere Pro and OTIO's own tools read.
///
/// Each of Montage's tracks becomes a track, video tracks bottom first and
/// then audio tracks, with gaps between the clips. In OTIO, as in Resolve
/// and Premiere, a video track carries only pictures, so the sound of each
/// video clip that plays its own goes on audio tracks after Montage's, one
/// for each video track, in step with the picture.
///
/// Media is referred to by its file's URL. Text and shapes, which no other
/// app could draw, are written as generators. Each clip's own settings
/// (volume, transform, effects, text) go in its metadata as Montage saves
/// them, so a file read back into Montage comes back as it was; other apps
/// keep metadata they don't understand, and ignore it.
struct OTIOExporter {
    let project: Project
    let name: String
    let mediaResolver: MediaResolver

    private var frameDuration: CMTime { project.settings.frameDuration }

    func document() -> Data {
        let videoTracks = project.tracks.filter { $0.kind == .video }
        let audioTracks = project.tracks.filter { $0.kind == .audio }
        var children: [OTIOJSON] = videoTracks.enumerated().map { index, track in
            trackJSON(track.clips.map { ($0, false) }, kind: track.kind, name: "V\(index + 1)", isEnabled: !track.isHidden)
        }
        children += audioTracks.enumerated().map { index, track in
            trackJSON(track.clips.map { ($0, false) }, kind: track.kind, name: "A\(index + 1)", isEnabled: !track.isMuted)
        }
        // The sound of the video tracks' clips, a track for each.
        var audioCount = audioTracks.count
        for track in videoTracks {
            let sounding = track.clips.filter(playsOwnSound)
            guard !sounding.isEmpty else { continue }
            audioCount += 1
            children.append(trackJSON(sounding.map { ($0, true) }, kind: .audio, name: "A\(audioCount)", isEnabled: !track.isHidden))
        }

        let markers: [OTIOJSON] = project.markers.map { marker in
            .schema("Marker.2", [
                ("metadata", .object([])), ("name", .string(marker.name)), ("color", .string("RED")),
                ("marked_range", OTIOTime.json(CMTimeRange(start: marker.time, duration: .zero), frameDuration: frameDuration)),
                ("comment", .string("")),
            ])
        }
        let stack = OTIOJSON.schema("Stack.1", [
            ("metadata", .object([])), ("name", .string("tracks")), ("source_range", .null), ("effects", .array([])),
            ("markers", .array(markers)), ("enabled", .bool(true)), ("children", .array(children)),
        ])
        let size = project.settings.renderSize
        let timeline = OTIOJSON.schema("Timeline.1", [
            ("metadata", .object([(OTIOJSON.montageKey, .object([
                ("width", .double(size.width)), ("height", .double(size.height)),
            ]))])),
            ("name", .string(name)),
            ("global_start_time", OTIOTime.json(CMTime.zero, frameDuration: frameDuration)),
            ("tracks", stack),
        ])
        return timeline.data()
    }

    /// Whether a clip on a video track plays its media's sound, which goes
    /// out on an audio track of its own.
    private func playsOwnSound(_ clip: Clip) -> Bool {
        guard case .media(let id) = clip.content, !clip.isAudioDetached, let item = project.mediaItem(id: id) else { return false }
        return item.kind == .video && item.metadata.hasAudio
    }

    // MARK: - Tracks

    /// A track of clips, with gaps where it has none. `isCompanion` marks
    /// the sound of a video clip.
    private func trackJSON(_ clips: [(Clip, Bool)], kind: Track.Kind, name: String, isEnabled: Bool) -> OTIOJSON {
        var children: [OTIOJSON] = []
        var cursor = CMTime.zero
        for (clip, isCompanion) in clips.sorted(by: { $0.0.timelineStart < $1.0.timelineStart }) {
            let range = clip.timelineRange
            guard range.duration > .zero, range.start >= cursor else { continue }
            if range.start > cursor { children.append(gapJSON(range.start - cursor)) }
            children.append(clipJSON(clip, isCompanion: isCompanion))
            cursor = range.end
        }
        return .schema("Track.1", [
            ("metadata", .object([])), ("name", .string(name)), ("source_range", .null), ("effects", .array([])),
            ("markers", .array([])), ("enabled", .bool(isEnabled)), ("children", .array(children)),
            ("kind", .string(kind == .video ? "Video" : "Audio")),
        ])
    }

    private func gapJSON(_ duration: CMTime) -> OTIOJSON {
        .schema("Gap.1", [
            ("metadata", .object([])), ("name", .string("")),
            ("source_range", OTIOTime.json(CMTimeRange(start: .zero, duration: duration), frameDuration: frameDuration)),
            ("effects", .array([])), ("markers", .array([])), ("enabled", .bool(true)),
        ])
    }

    // MARK: - Clips

    private func clipJSON(_ clip: Clip, isCompanion: Bool) -> OTIOJSON {
        let item = project.mediaItem(id: clip.mediaID)
        let reference: OTIOJSON
        let name: String
        var start = clip.sourceRange.start
        switch clip.content {
        case .media, .image:
            name = item.map { ($0.name as NSString).deletingPathExtension } ?? "Clip"
            reference = mediaReference(for: item)
            if item?.kind == .image { start = .zero }
        case .text(let text):
            name = text.string.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Text"
            reference = generatorReference(kind: "Text", parameters: [("text", .string(text.string))])
            start = .zero
        case .shape:
            name = "Shape"
            reference = generatorReference(kind: "Shape", parameters: [])
            start = .zero
        }

        var montage: [(String, OTIOJSON)] = []
        if isCompanion {
            montage.append(("companion", .bool(true)))
        } else if let saved = Self.savedClip(clip) {
            montage.append(("clip", saved))
        }
        return .schema("Clip.2", [
            ("metadata", .object(montage.isEmpty ? [] : [(OTIOJSON.montageKey, .object(montage))])),
            ("name", .string(name)),
            ("source_range", OTIOTime.json(CMTimeRange(start: start, duration: clip.duration), frameDuration: frameDuration)),
            ("effects", .array(Self.timeWarp(clip).map { [$0] } ?? [])), ("markers", .array([])), ("enabled", .bool(true)),
            ("media_references", .object([("DEFAULT_MEDIA", reference)])),
            ("active_media_reference_key", .string("DEFAULT_MEDIA")),
        ])
    }

    /// A clip's speed, where it isn't its media's own, as OTIO has it: the
    /// clip's range is its length on the timeline, and the media plays
    /// that many times as fast.
    private static func timeWarp(_ clip: Clip) -> OTIOJSON? {
        guard clip.content.hasSourceTime, !clip.speed.isNormal else { return nil }
        return .schema("LinearTimeWarp.1", [
            ("metadata", .object([])), ("name", .string("")), ("effect_name", .string("LinearTimeWarp")),
            ("time_scalar", .double(clip.speed.rate)),
        ])
    }

    /// The clip as Montage saves it, to read back exactly.
    private static func savedClip(_ clip: Clip) -> OTIOJSON? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(clip), let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return OTIOJSON(object)
    }

    /// The media's file, by URL; a missing reference where there's no file
    /// to point to.
    private func mediaReference(for item: MediaItem?) -> OTIOJSON {
        let available: OTIOJSON = if let item, item.kind != .image, item.metadata.duration > .zero {
            OTIOTime.json(CMTimeRange(start: .zero, duration: item.metadata.duration), frameDuration: frameDuration)
        } else {
            .null
        }
        let fields: [(String, OTIOJSON)] = [
            ("metadata", .object([])), ("name", .string(item?.name ?? "")), ("available_range", available),
            ("available_image_bounds", .null),
        ]
        guard let item, let url = url(for: item) else { return .schema("MissingReference.1", fields) }
        return .schema("ExternalReference.1", fields + [("target_url", .string(url))])
    }

    private func generatorReference(kind: String, parameters: [(String, OTIOJSON)]) -> OTIOJSON {
        .schema("GeneratorReference.1", [
            ("metadata", .object([])), ("name", .string(kind)), ("available_range", .null),
            ("available_image_bounds", .null), ("generator_kind", .string(kind)), ("parameters", .object(parameters)),
        ])
    }

    private func url(for item: MediaItem) -> String? {
        if let url = mediaResolver.url(for: item) { return url.absoluteString }
        if case .package(let path) = item.location {
            return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        }
        return nil
    }
}
