import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

/// Reads LumaFusion's own project file, the JSON `*.lfarchive` in its
/// project packages.
///
/// The layout was worked out from real packages written by LumaFusion for
/// Android 2.6, and checked against what an open-source reader says of
/// LumaFusion for iOS 5.5, which writes the same layout:
///
/// - The project has a `title`, a `resolution` of `[width, height]`, and a
///   `stepTime`, the length of a frame. Times are Core Media times written as
///   `{value, timescale, flags, epoch}`.
/// - `tracks` holds every track. `trackType` 0 is a video track, whose clips
///   play their picture and sound, and 1 an audio track. `trackOffset` places
///   it: the main track, `isAnchorTrack`, is 0, overlays count up from it
///   and audio tracks count down from -1.
/// - Each clip has its place on the timeline, `trackStart` and
///   `trackDuration`, and `streams`: the picture (`mediaType` 0) and the
///   sound (`mediaType` 1) it plays from its file, each with its in point,
///   `sourceStart` (`sourceRange.start` on iOS), and its settings in
///   `streamAttributes`. LumaFusion for iOS writes a photo's picture as
///   `mediaType` 2 and a title's as 3. `assetType` is 0 for a video file
///   (or, on Android, a sound file), 1 for a sound file on iOS, 2 for a
///   photo and 4 for a title; `assetIsBlank` marks a gap.
/// - A clip's file is named in `attributes`. `attributes.mediaMap` at the
///   top names each file as it's stored in the package, by asset ID.
///
/// Settings are `{value: {type, value}, keyframes}`. Volume, opacity and pan
/// are read as they are; scale and position as far as they can be, the
/// position assumed to run from -1 to 1 across the frame, up being positive;
/// everything else that's changed from its default goes in the report.
///
/// LumaFusion for iOS 3.1 keeps scale, position and rotation in one
/// setting, `videoTransform`, whose value is `{scaling, translation,
/// anchorPoint, rotation}`, keyframed at `clipTime`, from the clip's start.
/// That's read with its keyframes. Its translation runs from -1 to 1 across
/// the frame as Android's does, but down is positive: lower-third templates
/// sit at about 0.5 to 0.8 and grow from points inside the frame only under
/// that reading. Its rotation is in radians, taken to be clockwise, as a
/// positive angle is in a frame whose y axis runs down. Beside the settings
/// each stream has a flat `parameters`, which holds their defaults rather
/// than the clip's own values, so it isn't read.
struct LumaFusionTimelineReader {
    private typealias Object = [String: Any]

    private var media = ImportedMedia()
    private var report = ImportReport(format: .lumaFusion)
    private var settings = ProjectSettings()
    /// The file names the package stores media under, by asset ID.
    private var packageNames: [String: String] = [:]

    /// The project in `data`; `LumaFusionError.unsupportedVersion` if it
    /// isn't laid out as this reader knows.
    static func read(_ data: Data, appVersion: String?) throws -> ImportedProject {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? Object else { throw LumaFusionError.damaged }
        guard let tracks = root["tracks"] as? [Object] else { throw LumaFusionError.unsupportedVersion(appVersion) }
        var reader = LumaFusionTimelineReader()
        return reader.run(root, tracks: tracks)
    }

    private mutating func run(_ root: Object, tracks: [Object]) -> ImportedProject {
        let attributes = root["attributes"] as? Object ?? [:]
        for (name, id) in attributes["mediaMap"] as? [String: String] ?? [:] { packageNames[id] = name }

        let size = Self.numbers(root["resolution"])
        if size.count == 2, size[0] > 0, size[1] > 0 { settings.renderSize = CGSize(width: size[0], height: size[1]) }
        // From 1 to 240 frames a second; anything else isn't a frame rate.
        if let step = Self.time(root["stepTime"]), step.seconds >= 1.0 / 240, step.seconds <= 1 {
            settings.frameDuration = step
        }
        reportMarkers(attributes)

        // Video tracks bottom first, then audio tracks down from the picture.
        let ordered = tracks.sorted { a, b in
            let (kindA, kindB) = (Self.int(a["trackType"]) ?? 0, Self.int(b["trackType"]) ?? 0)
            if kindA != kindB { return kindA < kindB }
            let (offsetA, offsetB) = (Self.int(a["trackOffset"]) ?? 0, Self.int(b["trackOffset"]) ?? 0)
            return kindA == 1 ? offsetA > offsetB : offsetA < offsetB
        }
        var videoTracks: [Track] = []
        var audioTracks: [Track] = []
        for track in ordered {
            for made in importTrack(track) {
                if made.kind == .video { videoTracks.append(made) } else { audioTracks.append(made) }
            }
        }

        var project = Project(settings: settings, media: media.items)
        project.tracks = videoTracks + audioTracks
        let title = (root["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ImportedProject(project: project, report: report, name: title, mediaSources: media.sources)
    }

    private mutating func reportMarkers(_ attributes: Object) {
        var markers = attributes["compositionMarkers"] as? [Any] ?? []
        for key in ["trackMarkers", "assetMarkers"] {
            for case let list as [Any] in (attributes[key] as? Object ?? [:]).values { markers += list }
        }
        for marker in markers {
            let marker = marker as? Object ?? [:]
            let name = ["title", "name", "text", "comment"].lazy.compactMap { marker[$0] as? String }.first ?? ""
            report.add(.marker(name: name), time: Self.time(marker["time"]))
        }
    }

    // MARK: - Tracks

    /// A LumaFusion track as Montage tracks: one, or more where clips
    /// overlap, with a clip that has only sound on a video track put on an
    /// audio track of its own.
    private mutating func importTrack(_ track: Object) -> [Track] {
        let type = Self.int(track["trackType"]) ?? 0
        let clips = (track["clips"] as? [Object] ?? []).sorted {
            (Self.time($0["trackStart"]) ?? .zero) < (Self.time($1["trackStart"]) ?? .zero)
        }
        guard type == 0 || type == 1 else {
            for clip in clips {
                report.add(.setting(name: "Track type \(type)"), clipName: Self.name(of: clip), time: Self.time(clip["trackStart"]))
            }
            return []
        }
        // A track's volume is its clips' gain; LumaFusion writes it
        // negative for a muted track, keeping the level to unmute to.
        let trackVolume = Self.double(track["trackVolume"]) ?? 1
        var placed: [(clip: Placed, hasTransition: Bool)] = []
        for clip in clips {
            guard var next = importClip(clip, onAudioTrack: type == 1, trackVolume: abs(trackVolume)) else { continue }
            let hasTransition = (Self.int(clip["transitionType"]) ?? 0) != 0
            if hasTransition {
                report.add(.transition(name: "Transition"), clipName: next.name, time: next.clip.timelineStart)
            }
            // Times in different timescales can overlap by less than a
            // frame where clips meet: the later starts where the earlier ends.
            if let last = placed.last, !hasTransition, !last.hasTransition {
                let overlap = last.clip.clip.timelineRange.intersection(next.clip.timelineRange)
                if overlap.duration > .zero, overlap.duration < settings.frameDuration,
                   let trimmed = next.clip.trimmed(to: CMTimeRange(start: overlap.end, end: next.clip.timelineRange.end)) {
                    next.clip = trimmed
                }
            }
            placed.append((next, hasTransition))
        }

        var assembler = TimelineAssembler()
        for (index, (clip, hasTransition)) in placed.enumerated() {
            // Where a transition joins two clips they overlap: the cut goes
            // in its middle.
            if index > 0, hasTransition || placed[index - 1].hasTransition {
                let overlap = placed[index - 1].clip.clip.timelineRange.intersection(clip.clip.timelineRange)
                if overlap.duration > .zero { assembler.addTransition(overlap, lane: 0) }
            }
            assembler.add(clip.clip, kind: clip.kind, lane: 0, name: clip.name)
        }
        return assembler.tracks(report: &report).map { made in
            var made = made
            made.isHidden = Self.bool(track["hidden"]) ?? false
            made.isMuted = trackVolume < 0
            return made
        }
    }

    // MARK: - Clips

    private struct Placed {
        var clip: Clip
        var kind: Track.Kind
        var name: String
    }

    private mutating func importClip(_ object: Object, onAudioTrack: Bool, trackVolume: Double) -> Placed? {
        let name = Self.name(of: object)
        guard let start = Self.time(object["trackStart"]), let duration = Self.time(object["trackDuration"]),
              start >= .zero, duration > .zero else { return nil }
        if Self.bool(object["assetIsBlank"]) == true { return nil }

        let assetType = Self.int(object["assetType"]) ?? 0
        switch assetType {
        case 0, 1, 2: break
        case 4:
            report.add(.title, clipName: name, time: start)
            return nil
        default:
            report.add(.generator(name: name), clipName: name, time: start)
            return nil
        }

        let streams = object["streams"] as? [Object] ?? []
        let videoTrackID = Self.int(object["useVideoTrackID"])
        let audioTrackID = Self.int(object["useAudioTrackID"])
        let pictures = streams.filter { Self.int($0["mediaType"]) != 1 }
        let sounds = streams.filter { Self.int($0["mediaType"]) == 1 }
        let picture = pictures.first { Self.int($0["assetTrackID"]) == videoTrackID } ?? pictures.first
        let sound = sounds.first { Self.int($0["assetTrackID"]) == audioTrackID } ?? sounds.first

        let item = mediaItem(for: object, assetType: assetType, picture: picture, sound: sound)
        let stream = picture ?? sound
        let sourceStart = item.kind == .image ? .zero
            : Self.time((stream?["sourceRange"] as? Object)?["start"]) ?? Self.time(stream?["sourceStart"]) ?? .zero
        var clip = Clip(mediaID: item.id, sourceRange: CMTimeRange(start: sourceStart, duration: duration), timelineStart: start)

        // Sound only, on an audio track or from a sound file: an audio clip.
        let kind: Track.Kind = onAudioTrack || item.kind == .audio || (picture == nil && sound != nil) ? .audio : .video
        if kind == .video, item.kind == .video, sound == nil { clip.isAudioDetached = true }

        var notes: [String] = []
        if Self.bool(object["reversed"]) == true { notes.append("Reverse") }
        if streams.contains(where: Self.isSpeedChanged) { report.add(.speedChange, clipName: name, time: start) }
        if let sound { applySound(sound.streamAttributes, to: &clip, trackVolume: trackVolume, notes: &notes) }
        if let picture, kind == .video { applyPicture(picture.streamAttributes, to: &clip, item: item, notes: &notes, name: name) }
        for stream in streams {
            for case let effect as Object in stream["effects"] as? [Any] ?? [] {
                addEffect(effect, isVideo: Self.int(stream["mediaType"]) != 1, to: &clip, clipName: name)
            }
        }
        for note in notes.uniqued() { report.add(.setting(name: note), clipName: name, time: start) }
        return Placed(clip: clip, kind: kind, name: name)
    }

    /// Volume and pan, which Montage has; ducking and fill, which it hasn't.
    private func applySound(_ attributes: Object, to clip: inout Clip, trackVolume: Double, notes: inout [String]) {
        if let volume = Self.setting(attributes["audioVolume"]) {
            clip.volume = Animatable(max(0, volume.numbers.first ?? 1) * trackVolume)
            if volume.isKeyframed { notes.append("Volume keyframes") }
        } else if trackVolume != 1 {
            clip.volume = Animatable(trackVolume)
        }
        if let pan = Self.setting(attributes["audioPan"]) {
            let position = min(1, max(-1, pan.numbers.first ?? 0))
            if position != 0 {
                var parameters = Pan()
                parameters.position = Animatable(position)
                clip.effects.append(Effect(.pan(parameters)))
            }
            if pan.isKeyframed { notes.append("Pan keyframes") }
        }
        for (key, label) in [("audioDuck", "Ducking"), ("audioFill", "Audio fill")] {
            guard let setting = Self.setting(attributes[key]) else { continue }
            if setting.isKeyframed || setting.numbers.contains(where: { $0 != 0 }) { notes.append(label) }
        }
    }

    /// Opacity, scale and position, which Montage has, and the rest of the
    /// picture's settings, which go in the report where they're changed.
    private mutating func applyPicture(_ attributes: Object, to clip: inout Clip, item: MediaItem, notes: inout [String], name: String) {
        if let alpha = Self.setting(attributes["videoAlpha"]) {
            clip.opacity = Animatable(min(1, max(0, alpha.numbers.first ?? 1)))
            if alpha.isKeyframed { notes.append("Opacity keyframes") }
        }
        if let transform = attributes["videoTransform"] as? Object {
            applyTransform(transform, to: &clip, notes: &notes, name: name)
        }
        if let scale = Self.setting(attributes["videoScale"]), scale.numbers.count == 2,
           scale.numbers.allSatisfy({ $0 > 0 }) {
            let (across, down) = (scale.numbers[0], scale.numbers[1])
            clip.transform.scale = Animatable((across + down) / 2)
            if abs(across - down) > 0.0001 { report.add(.uneven(name: "Scale"), clipName: name, time: clip.timelineStart) }
            if scale.isKeyframed { notes.append("Scale keyframes") }
        }
        if let translation = Self.setting(attributes["videoTranslation"]), translation.numbers.count == 2 {
            let (x, y) = (translation.numbers[0], translation.numbers[1])
            clip.transform.position = Animatable(CGPoint(x: 0.5 + x / 2, y: 0.5 - y / 2))
            if translation.isKeyframed { notes.append("Position keyframes") }
        }
        // A turn by a quarter is the file's own orientation, which the
        // file carries and Montage applies itself.
        for key in ["videoRotation", "videoTransformRotation", "videoOrientation"] {
            guard let rotation = Self.setting(attributes[key]) else { continue }
            let quarters = (rotation.numbers.first ?? 0) / (.pi / 2)
            if rotation.isKeyframed || abs(quarters - quarters.rounded()) > 0.0001 { notes.append("Rotation") }
        }
        let defaults: [(key: String, label: String, value: [Double])] = [
            ("videoCrop", "Crop", [0, 0, 1, 1]), ("videoCropCorner", "Crop", [0]), ("videoCropSoftness", "Crop", [0]),
            ("videoCropInverted", "Crop", [0]), ("videoFlipH", "Flip", [0]), ("videoFlipV", "Flip", [0]),
            ("videoAnchor", "Anchor point", [0, 0]), ("videoBlendMode", "Blend mode", [0]),
        ]
        for (key, label, value) in defaults {
            guard let setting = Self.setting(attributes[key]) else { continue }
            let changed = setting.numbers.count != value.count || zip(setting.numbers, value).contains { abs($0 - $1) > 0.0001 }
            if changed || setting.isKeyframed { notes.append(label) }
        }
    }

    /// One value of LumaFusion for iOS's `videoTransform`.
    private struct Transform {
        var scaling: [Double]
        var translation: [Double]
        var anchorPoint: [Double]
        /// In radians.
        var rotation: Double

        init?(_ value: Any?) {
            // A setting's value is `{type: 5, value: {scaling, ...}}`.
            guard let outer = value as? [String: Any] else { return nil }
            let object = outer["scaling"] == nil ? outer["value"] as? [String: Any] ?? [:] : outer
            scaling = LumaFusionTimelineReader.numbers(object["scaling"])
            translation = LumaFusionTimelineReader.numbers(object["translation"])
            anchorPoint = LumaFusionTimelineReader.numbers(object["anchorPoint"])
            let rotation = LumaFusionTimelineReader.numbers(object["rotation"])
            guard scaling.count == 2, translation.count == 2, rotation.count <= 1 else { return nil }
            if anchorPoint.count != 2 { anchorPoint = [0.5, 0.5] }
            self.rotation = rotation.first ?? 0
        }

        /// Montage's scale: across and down averaged.
        var scale: Double { (abs(scaling[0]) + abs(scaling[1])) / 2 }
        /// The centre as a fraction of the frame, from a translation that
        /// runs from -1 to 1 across it, down being positive.
        var position: CGPoint { CGPoint(x: 0.5 + translation[0] / 2, y: 0.5 + translation[1] / 2) }
        /// Clockwise, in degrees.
        var degrees: Double { rotation * 180 / .pi }
        var isUneven: Bool { abs(abs(scaling[0]) - abs(scaling[1])) > 0.0001 }
        var isFlipped: Bool { scaling.contains { $0 < 0 } }
        var isAnchorMoved: Bool { abs(anchorPoint[0] - 0.5) > 0.0001 || abs(anchorPoint[1] - 0.5) > 0.0001 }
    }

    /// LumaFusion for iOS's scale, position and rotation, with their
    /// keyframes. An anchor point away from the middle, uneven or flipped
    /// scale, eased keyframes and curved motion paths go in the report.
    private mutating func applyTransform(_ setting: Object, to clip: inout Clip, notes: inout [String], name: String) {
        guard let base = Transform(setting["value"]) else {
            notes.append("Transform")
            return
        }
        var keyframes: [(time: CMTime, value: Transform)] = []
        for case let keyframe as Object in setting["keyframes"] as? [Any] ?? [] {
            guard let time = Self.time(keyframe["clipTime"]) ?? Self.time(keyframe["time"]), time >= .zero,
                  let value = Transform(keyframe["value"]) else {
                notes.append("Transform keyframes")
                continue
            }
            if Self.interpolationType(keyframe["interpolation"]) != 0 { notes.append("Keyframe easing") }
            if Self.interpolationType(keyframe["spatialInterpolation"]) != 0 { notes.append("Motion path") }
            keyframes.append((time, value))
        }
        let values = [base] + keyframes.map(\.value)
        if values.contains(where: \.isUneven) {
            report.add(.uneven(name: "Scale"), clipName: name, time: clip.timelineStart)
        }
        if values.contains(where: \.isFlipped) { notes.append("Flip") }
        if values.contains(where: \.isAnchorMoved) { notes.append("Anchor point") }

        clip.transform.scale = Self.animatable(base.scale, keyframes.map { ($0.time, $0.value.scale) })
        clip.transform.position = Self.animatable(base.position, keyframes.map { ($0.time, $0.value.position) })
        clip.transform.rotation = Self.animatable(base.degrees, keyframes.map { ($0.time, $0.value.degrees) })
    }

    /// A value keyframed where its keyframes differ; where they don't, the
    /// one value they all hold. Of keyframes at the same time the last wins.
    private static func animatable<Value: Interpolatable>(_ value: Value, _ keyframes: [(CMTime, Value)]) -> Animatable<Value> {
        guard let first = keyframes.first else { return Animatable(value) }
        if keyframes.allSatisfy({ $0.1 == first.1 }) { return Animatable(first.1) }
        var animatable = Animatable(value)
        for (time, value) in keyframes { animatable.setKeyframe(Keyframe(time: time, value: value)) }
        return animatable
    }

    /// A keyframe's interpolation type: written as `{type, controlPointIn,
    /// controlPointOut}`, or as a bare number. 0, linear, is the only one
    /// seen; nil and 0 are both read as linear.
    private static func interpolationType(_ value: Any?) -> Int {
        if let object = value as? Object { return int(object["type"]) ?? 0 }
        return int(value) ?? 0
    }

    private mutating func addEffect(_ effect: Object, isVideo: Bool, to clip: inout Clip, clipName: String) {
        let identifier = ["effectID", "effectName", "identifier"].lazy.compactMap { effect[$0] as? String }.first ?? ""
        let name = ["displayName", "effectName", "name"].lazy.compactMap { effect[$0] as? String }.first { !$0.isEmpty }
            ?? (identifier.isEmpty ? "Effect" : identifier)
        report.add(.unsupportedEffect(name: name), clipName: clipName, time: clip.timelineStart)
        let original = (try? JSONSerialization.data(withJSONObject: effect, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
        clip.effects.append(Effect(isEnabled: false, .unsupported(UnsupportedEffect(
            format: InterchangeFormat.lumaFusion.rawValue, identifier: identifier, name: name, isVideo: isVideo,
            original: original
        ))))
    }

    private static func isSpeedChanged(_ stream: Object) -> Bool {
        if let speed = double(stream["sourceSpeed"]), abs(speed - 1) > 0.0001 { return true }
        guard let speed = setting(stream.streamAttributes["speed"]) else { return false }
        return speed.isKeyframed || abs((speed.numbers.first ?? 1) - 1) > 0.0001
    }

    // MARK: - Media

    private mutating func mediaItem(for clip: Object, assetType: Int, picture: Object?, sound: Object?) -> MediaItem {
        let attributes = clip["attributes"] as? Object ?? [:]
        let assetID = attributes["assetID"] as? String
        let original = attributes["originalFilename"] as? String ?? ""
        let fromURL = (clip["assetURL"] as? String).flatMap { URL(string: $0)?.lastPathComponent } ?? ""
        // The name the package stores the file under, then the names the
        // clip gives it; one without an extension is a placeholder.
        let names = [assetID.flatMap { packageNames[$0] }, Self.lastComponent(original), attributes["title"] as? String, fromURL]
            .compactMap { $0 }.filter { !$0.isEmpty }
        let name = names.first { !($0 as NSString).pathExtension.isEmpty } ?? names.first ?? "Media"
        // Where the file was, when that's a path rather than LumaFusion's
        // own library.
        let source = original.hasPrefix("/") ? URL(fileURLWithPath: original) : nil

        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        let kind: MediaItem.Kind = if assetType == 2 || type?.conforms(to: .image) == true { .image }
            else if assetType == 1 || type?.conforms(to: .audio) == true || (picture == nil && sound != nil) { .audio }
            else { .video }

        var metadata = MediaMetadata(duration: kind == .image ? .zero : Self.time(clip["assetMaxDuration"]) ?? .zero)
        let size = Self.numbers(attributes["naturalSize"])
        if kind != .audio, size.count == 2 { metadata.naturalSize = CGSize(width: size[0], height: size[1]) }
        if kind == .video, let step = Self.time(picture?["originalStepTime"]), step > .zero {
            metadata.nominalFrameRate = 1 / step.seconds
        }
        if kind != .image, sound != nil {
            metadata.audioChannelCount = 2
            metadata.audioSampleRate = Self.double(attributes["audioSamplerate"]) ?? 48000
        }
        return media.item(key: assetID ?? name, url: source, name: name, kind: kind, metadata: metadata)
    }

    // MARK: - Values

    private static func name(of clip: Object) -> String {
        let attributes = clip["attributes"] as? Object
        return [clip["title"], attributes?["title"]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
    }

    private static func lastComponent(_ path: String) -> String {
        String(path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? "")
    }

    /// A Core Media time as LumaFusion writes it; nil unless it's a valid,
    /// finite time.
    static func time(_ value: Any?) -> CMTime? {
        guard let object = value as? [String: Any], let count = int64(object["value"]),
              let timescale = int64(object["timescale"]), timescale > 0 else { return nil }
        let flags = int64(object["flags"]) ?? 1
        // Valid, and not infinite or indefinite.
        guard flags & 1 != 0, flags & (4 | 8 | 16) == 0 else { return nil }
        return InterchangeTime.time(count, over: timescale)
    }

    /// A setting's value, as numbers, and whether it has keyframes.
    private static func setting(_ value: Any?) -> (numbers: [Double], isKeyframed: Bool)? {
        guard let object = value as? [String: Any] else { return nil }
        let inner = (object["value"] as? [String: Any])?["value"] ?? object["value"]
        let isKeyframed = !((object["keyframes"] as? [Any])?.isEmpty ?? true)
        return (numbers(inner), isKeyframed)
    }

    /// Every number in a value, in order: booleans count as 0 or 1, a
    /// position reads its `point`, and a string such as "[0.0 0.0]" its
    /// numbers.
    static func numbers(_ value: Any?) -> [Double] {
        switch value {
        case let number as NSNumber: [number.doubleValue]
        case let list as [Any]: list.flatMap(numbers)
        case let object as [String: Any]: numbers(object["point"])
        case let string as String:
            string.split(whereSeparator: { "[], ".contains($0) }).compactMap { Double($0) }
        default: []
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, abs(double) < 9e18 else { return nil }
        return number.int64Value
    }

    private static func int(_ value: Any?) -> Int? { int64(value).map { Int(truncatingIfNeeded: $0) } }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.doubleValue.isFinite ? number.doubleValue : nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber).map(\.boolValue)
    }
}

private extension Dictionary where Key == String, Value == Any {
    var streamAttributes: [String: Any] { self["streamAttributes"] as? [String: Any] ?? [:] }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}

/// Reads the projects of every version of LumaFusion whose project file
/// has the layout `LumaFusionTimelineReader` knows; the rest are refused.
struct LumaFusionNativeDecoder: LumaFusionProjectDecoder {
    func supports(appVersion: String) -> Bool { true }

    func decode(_ file: LumaFusionProjectFile, in package: LumaFusionPackage) throws -> ImportedProject {
        try LumaFusionTimelineReader.read(file.data, appVersion: file.appVersion)
    }
}
