import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

/// Reads a sequence from Final Cut Pro 7 XML (`xmeml`), the format Premiere
/// Pro exports with File > Export > Final Cut Pro XML.
///
/// It's track based, as Montage is, so the tracks come across as they are:
/// video tracks bottom first, then audio tracks. Times are counted in frames
/// at a rate given as a whole-number timebase, slowed by 1000/1001 for NTSC.
/// A clip's picture and its sound are separate clips on video and audio
/// tracks, linked; where the sound is in step with the picture they're made
/// one clip, which plays both, and otherwise the picture's clip has its
/// audio detached and the sound clips play it.
///
/// What Montage keeps as clip settings (motion, opacity, audio levels and
/// pan) Final Cut 7 writes as effects, so those are read as settings.
struct XMEMLImporter {
    private var files: [String: MarkupElement] = [:]
    private let baseURL: URL?
    private var media = ImportedMedia()
    private var assembler = TimelineAssembler()
    private var report = ImportReport(format: .xmeml)
    private var settings = ProjectSettings()
    /// The audio clip items made part of a picture's clip, by ID.
    private var mergedAudio: Set<String> = []

    static func read(_ root: MarkupElement, baseURL: URL?) throws -> ImportedProject {
        var importer = XMEMLImporter(root: root, baseURL: baseURL)
        return try importer.run(root)
    }

    private init(root: MarkupElement, baseURL: URL?) {
        self.baseURL = baseURL
        // A file is written out in full the first time it's used, and by
        // its ID alone after that.
        for file in root.allDescendants where file.name == "file" && !file.children.isEmpty {
            if let id = file["id"], files[id] == nil { files[id] = file }
        }
    }

    private mutating func run(_ root: MarkupElement) throws -> ImportedProject {
        // Sequences at the top, or in a project's bin; not those nested in clips.
        let sequences = root.children("sequence") + root.children("project").flatMap {
            ([$0] + $0.allDescendants).filter { $0.name == "children" }.flatMap { $0.children("sequence") }
        }
        guard let sequence = sequences.first else { throw InterchangeError.noTimeline }
        if sequences.count > 1 { report.add(.otherTimelines(count: sequences.count - 1)) }

        let rate = Self.frameDuration(of: sequence)
        settings.frameDuration = rate
        if let characteristics = sequence.descendant("media", "video", "format", "samplecharacteristics"),
           let width = Double(characteristics.child("width")?.text ?? ""),
           let height = Double(characteristics.child("height")?.text ?? ""), width > 0, height > 0 {
            settings.renderSize = CGSize(width: width, height: height)
        }

        for marker in sequence.children("marker") {
            report.add(.marker(name: marker.child("name")?.text ?? ""), time: frames(marker.child("in")?.text, rate))
        }
        importTracks(of: sequence, base: .zero, origin: .zero, lane: 0, window: nil)

        var project = Project(settings: settings, media: media.items)
        project.tracks = assembler.tracks(report: &report)
        return ImportedProject(
            project: project, report: report, name: sequence.child("name")?.text, mediaSources: media.sources
        )
    }

    // MARK: - Tracks

    /// A sequence's tracks, placed so its time `origin` falls at `base` on
    /// the timeline: the top sequence's at zero, a nested one's where its
    /// clip is.
    private mutating func importTracks(of sequence: MarkupElement, base: CMTime, origin: CMTime, lane: Int, window: CMTimeRange?) {
        let rate = Self.frameDuration(of: sequence)
        let audioItems = (sequence.descendant("media", "audio")?.children("track") ?? []).flatMap { $0.children("clipitem") }
        let placement = Placement(base: base, origin: origin, rate: rate, window: window)

        for (index, track) in (sequence.descendant("media", "video")?.children("track") ?? []).enumerated() {
            importTrack(track, kind: .video, lane: lane + index, placement: placement, audioItems: audioItems)
        }
        for (index, track) in (sequence.descendant("media", "audio")?.children("track") ?? []).enumerated() {
            importTrack(track, kind: .audio, lane: lane - index, placement: placement, audioItems: [])
        }
    }

    private struct Placement {
        /// The timeline time of `origin`, a time in the sequence.
        var base: CMTime
        var origin: CMTime
        /// The sequence's frame length, which its times are counted in.
        var rate: CMTime
        var window: CMTimeRange?

        func timeline(_ time: CMTime) -> CMTime { base + (time - origin) }
    }

    private mutating func importTrack(
        _ track: MarkupElement, kind: Track.Kind, lane: Int, placement: Placement, audioItems: [MarkupElement]
    ) {
        let isTrackEnabled = track.child("enabled")?.text.uppercased() != "FALSE"
        // The last transition, for a clip that starts inside it.
        var transitionStart: CMTime?
        // Where the last transition put its cut, for a clip that starts inside it.
        var transitionCut: CMTime?
        for (index, item) in track.children.enumerated() {
            switch item.name {
            case "transitionitem":
                let start = frames(item.child("start")?.text, placement.rate) ?? .zero
                let end = frames(item.child("end")?.text, placement.rate) ?? start
                let range = CMTimeRange(start: placement.timeline(start), end: placement.timeline(end))
                assembler.addTransition(range, lane: lane)
                report.add(.transition(name: item.descendant("effect", "name")?.text ?? "Transition"), time: range.start)
                transitionStart = start
                transitionCut = Self.cut(of: item, start: start, end: end)
            case "clipitem":
                guard isTrackEnabled else {
                    report.add(.disabledClip, clipName: item.child("name")?.text, time: frames(item.child("start")?.text, placement.rate))
                    continue
                }
                // The transition the clip ends inside, if it does.
                let next = track.children[(index + 1)...].prefix { $0.name != "clipitem" }.first { $0.name == "transitionitem" }
                let nextCut = next.flatMap { transition in
                    frames(transition.child("start")?.text, placement.rate).map { start in
                        Self.cut(of: transition, start: start, end: frames(transition.child("end")?.text, placement.rate) ?? start)
                    }
                }
                let cuts = transitionCut.flatMap { previous in nextCut.map { (previous, $0) } }
                importClipItem(item, kind: kind, lane: lane, placement: placement, transitionStart: transitionStart, cuts: cuts,
                               audioItems: audioItems)
            case "generatoritem":
                report.add(.generator(name: item.descendant("effect", "name")?.text ?? item.child("name")?.text ?? ""),
                           clipName: item.child("name")?.text,
                           time: frames(item.child("start")?.text, placement.rate).map(placement.timeline))
            default:
                break
            }
        }
    }

    // MARK: - Clips

    private mutating func importClipItem(
        _ item: MarkupElement, kind: Track.Kind, lane: Int, placement: Placement, transitionStart: CMTime?,
        cuts: (CMTime, CMTime)? = nil,
        audioItems: [MarkupElement]
    ) {
        if let id = item["id"], mergedAudio.contains(id) { return }
        let name = item.child("name")?.text
        let clipRate = item.child("rate").map(Self.frameDuration(of:)) ?? placement.rate
        let writtenIn = frames(item.child("in")?.text, clipRate) ?? .zero
        let sourceOut = frames(item.child("out")?.text, clipRate) ?? writtenIn
        let duration = sourceOut - writtenIn
        // Inside a transition, the start or end is written as -1.
        let start = frames(item.child("start")?.text, placement.rate)
        let end = frames(item.child("end")?.text, placement.rate)
        // Between two transitions, Final Cut 7 and Premiere count a clip
        // from where the first starts, its overlap included. Resolve gives
        // it only the length it plays from cut to cut, but still counts its
        // in point from where the first transition starts; its sound,
        // written without the transition, shows it. Such a clip starts at
        // the first cut, that far into its media.
        var inside = transitionStart
        var sourceIn = writtenIn
        if let (previous, next) = cuts, let transitionStart, start == nil, end == nil, next - previous == duration {
            inside = previous
            sourceIn = writtenIn + (previous - transitionStart)
        }
        guard let sequenceStart = start ?? end.map({ $0 - duration }) ?? inside, duration > .zero else { return }
        let timelineStart = placement.timeline(sequenceStart)

        for marker in item.children("marker") {
            let at = frames(marker.child("in")?.text, clipRate).map { timelineStart + ($0 - sourceIn) }
            report.add(.marker(name: marker.child("name")?.text ?? ""), clipName: name, time: at)
        }
        if item.child("enabled")?.text.uppercased() == "FALSE" {
            report.add(.disabledClip, clipName: name, time: timelineStart)
            return
        }
        let clipRange = CMTimeRange(start: timelineStart, duration: duration)
        let window = placement.window.map { $0.intersection(clipRange) } ?? clipRange

        // A nested sequence: its clips, played from the clip's in point.
        if let nested = item.child("sequence") {
            if !item.children("filter").isEmpty { report.add(.nestedSettings, clipName: name, time: timelineStart) }
            importTracks(of: nested, base: timelineStart, origin: sourceIn, lane: lane, window: window)
            return
        }
        if item.child("multiclip") != nil {
            report.add(.setting(name: "Multiclip"), clipName: name, time: timelineStart)
            return
        }
        guard let file = item.child("file").flatMap({ $0["id"].flatMap { files[$0] } ?? $0 }) else { return }
        // Resolve writes a compound clip as a file with an empty path and no
        // type, and leaves out what's inside it. Premiere leaves the path out
        // of its own synthetic media, such as Black Video, which it names
        // a source of instead, and those come in as missing media.
        if let path = file.child("pathurl"), path.text.isEmpty, file.child("mediaSource") == nil,
           ((file.child("name")?.text ?? name ?? "") as NSString).pathExtension.isEmpty {
            report.add(.setting(name: "Compound clip"), clipName: name, time: timelineStart)
            return
        }

        let mediaItem = mediaItem(for: file)
        var clip = Clip(
            content: mediaItem.content,
            sourceRange: CMTimeRange(start: mediaItem.kind == .image ? .zero : sourceIn, duration: duration),
            timelineStart: timelineStart
        )
        let toClip: (CMTime) -> CMTime = { $0 - sourceIn }
        var settingsFrom = [item]

        if kind == .video, mediaItem.kind != .audio {
            // The sound in step with this picture, if it's on the timeline.
            let inStep = audioItems.filter { audio in
                audio.child("file")?["id"] == file["id"]
                    && audio.child("start")?.text == item.child("start")?.text && audio.child("end")?.text == item.child("end")?.text
                    && audio.child("in")?.text == item.child("in")?.text && audio.child("out")?.text == item.child("out")?.text
                    && audio.child("enabled")?.text.uppercased() != "FALSE"
            }
            if let first = inStep.first {
                mergedAudio.formUnion(inStep.compactMap { $0["id"] })
                settingsFrom.append(first)
            } else if mediaItem.metadata.hasAudio {
                clip.isAudioDetached = true
            }
        } else if kind == .audio {
            // A stereo pair is two clip items of one file, a channel each;
            // Montage plays the file's sound whole, so one clip is enough.
            if let id = item["id"] { mergedAudio.insert(id) }
            mergedAudio.formUnion(audioItems.filter {
                $0.child("file")?["id"] == file["id"] && $0.child("start")?.text == item.child("start")?.text
                    && $0.child("in")?.text == item.child("in")?.text
            }.compactMap { $0["id"] })
        }

        for source in settingsFrom {
            applyFilters(of: source, to: &clip, item: mediaItem, isVideo: kind == .video, clipRate: clipRate,
                         toClip: toClip, clipName: name ?? mediaItem.name)
        }
        if let trimmed = clip.trimmed(to: window) {
            assembler.add(trimmed, kind: mediaItem.kind == .audio ? .audio : kind, lane: lane, name: name ?? mediaItem.name)
        }
    }

    /// Final Cut 7 writes clip settings as effects: those Montage keeps as
    /// settings are read into them, effects that map onto Montage's become
    /// those, and anything else is kept turned off.
    private mutating func applyFilters(
        of item: MarkupElement, to clip: inout Clip, item mediaItem: MediaItem, isVideo: Bool, clipRate: CMTime,
        toClip: @escaping (CMTime) -> CMTime, clipName: String
    ) {
        // Read parameters through a copy: the lookups outlive this change.
        let reader = self
        for filter in item.children("filter") {
            guard let effect = filter.child("effect") else { continue }
            let id = effect.child("effectid")?.text ?? ""
            let name = effect.child("name")?.text ?? id
            let isEnabled = filter.child("enabled")?.text.uppercased() != "FALSE"
            let parameters = effect.children("parameter")
            func number(_ wanted: String) -> Animatable<Double>? {
                guard let parameter = parameters.first(where: {
                    ($0.child("parameterid")?.text ?? $0.child("name")?.text ?? "").lowercased() == wanted.lowercased()
                        || $0.child("name")?.text.lowercased() == wanted.lowercased()
                }) else { return nil }
                return reader.animatable(parameter, clipRate: clipRate, toClip: toClip) { Double($0.text) }
            }
            let effectIsVideo = effect.child("mediatype")?.text != "audio"

            switch id.lowercased() {
            case "basic":
                guard isEnabled else { continue }
                applyMotion(effect, to: &clip, item: mediaItem, clipRate: clipRate, toClip: toClip)
            case "opacity":
                if isEnabled, let opacity = number("opacity") { clip.opacity = opacity.mapped { max(0, min(1, $0 / 100)) } }
            case "audiolevels":
                if isEnabled, let level = number("level") { clip.volume = level.mapped { max(0, $0) } }
            case "audiopan":
                if isEnabled, let pan = number("pan"), pan.isAnimated || pan.value != 0 {
                    var parameters = Pan()
                    parameters.position = pan.mapped { max(-1, min(1, $0)) }
                    clip.effects.append(Effect(.pan(parameters)))
                }
            case "timeremap":
                // Played backwards, or along a speed graph, at a speed of 100.
                let isReversed = parameters.contains {
                    $0.child("parameterid")?.text.lowercased() == "reverse" && $0.child("value")?.text.uppercased() == "TRUE"
                }
                let isVariable = number("variablespeed").map { $0.value != 0 } ?? false
                if isReversed || isVariable || number("speed").map({ $0.isAnimated || abs($0.value - 100) > 0.001 }) == true {
                    report.add(.speedChange, clipName: clipName, time: clip.timelineStart)
                }
            case "crop":
                if isEnabled, parameters.contains(where: { Double($0.child("value")?.text ?? "") ?? 0 != 0 }) {
                    report.add(.setting(name: "Crop"), clipName: clipName, time: clip.timelineStart)
                }
            default:
                let lookup = ImportedParameters { number($0) }
                if let kind = EffectMapping.xmeml(id: id, name: name, parameters: lookup, frameWidth: settings.renderSize.width) {
                    clip.effects.append(Effect(isEnabled: isEnabled, kind))
                    continue
                }
                report.add(.unsupportedEffect(name: name), clipName: clipName, time: clip.timelineStart)
                clip.effects.append(Effect(isEnabled: false, .unsupported(UnsupportedEffect(
                    format: InterchangeFormat.xmeml.rawValue, identifier: id, name: name, isVideo: effectIsVideo,
                    parameters: parameters.map { parameter in
                        .init(name: parameter.child("name")?.text ?? parameter.child("parameterid")?.text ?? "",
                              key: parameter.child("parameterid")?.text,
                              value: parameter.child("value").map { $0.children.isEmpty ? $0.text : $0.children.map(\.text).joined(separator: " ") },
                              isAnimated: parameter.child("keyframe") != nil)
                    },
                    original: filter.xmlString()
                ))))
            }
        }
    }

    /// Basic Motion: scale in percent of the media's own size, rotation
    /// clockwise in degrees, and the centre as a fraction of the frame from
    /// its middle.
    private mutating func applyMotion(
        _ effect: MarkupElement, to clip: inout Clip, item: MediaItem, clipRate: CMTime, toClip: @escaping (CMTime) -> CMTime
    ) {
        let parameters = effect.children("parameter")
        func parameter(_ id: String) -> MarkupElement? {
            parameters.first { $0.child("parameterid")?.text.lowercased() == id }
        }
        // Montage's pictures start fitted to the frame.
        let media = item.metadata.presentationSize
        let frame = settings.renderSize
        let fit = media.width > 0 && media.height > 0 ? min(frame.width / media.width, frame.height / media.height) : 1
        if let scale = parameter("scale").flatMap({ animatable($0, clipRate: clipRate, toClip: toClip) { Double($0.text) } }) {
            clip.transform.scale = scale.mapped { $0 / 100 / fit }
        }
        if let rotation = parameter("rotation").flatMap({ animatable($0, clipRate: clipRate, toClip: toClip) { Double($0.text) } }) {
            clip.transform.rotation = rotation
        }
        if let center = parameter("center").flatMap({ animatable($0, clipRate: clipRate, toClip: toClip, Self.point) }) {
            clip.transform.position = center
        }
        if let offset = parameter("centeroffset").flatMap({ animatable($0, clipRate: clipRate, toClip: toClip, Self.point) }),
           offset.isAnimated || offset.value != CGPoint(x: 0.5, y: 0.5) {
            report.add(.setting(name: "Anchor point"), clipName: item.name, time: clip.timelineStart)
        }
    }

    /// A centre as a Montage position: across and down from the top left.
    private static func point(_ value: MarkupElement) -> CGPoint? {
        guard let horizontal = Double(value.child("horiz")?.text ?? ""), let vertical = Double(value.child("vert")?.text ?? "") else {
            return nil
        }
        return CGPoint(x: 0.5 + horizontal, y: 0.5 + vertical)
    }

    /// A parameter's value, and its keyframes, timed from the clip's start.
    private func animatable<Value>(
        _ parameter: MarkupElement, clipRate: CMTime, toClip: (CMTime) -> CMTime, _ parse: (MarkupElement) -> Value?
    ) -> Animatable<Value>? {
        let keyframes = parameter.children("keyframe").compactMap { keyframe -> Keyframe<Value>? in
            guard let when = frames(keyframe.child("when")?.text, clipRate),
                  let value = keyframe.child("value").flatMap(parse) else { return nil }
            return Keyframe(time: toClip(when), value: value)
        }
        guard let value = parameter.child("value").flatMap(parse) ?? keyframes.first?.value else { return nil }
        return Animatable(value, keyframes: keyframes)
    }

    // MARK: - Media

    private mutating func mediaItem(for file: MarkupElement) -> MediaItem {
        let url = ImportedMedia.url(from: file.child("pathurl")?.text, relativeTo: baseURL)
        let name = file.child("name")?.text ?? url?.lastPathComponent ?? "Media"
        let rate = file.child("rate").map(Self.frameDuration(of:)) ?? settings.frameDuration
        let video = file.descendant("media", "video")
        let audio = file.descendant("media", "audio")
        let fileType = url.flatMap { UTType(filenameExtension: $0.pathExtension) }
            ?? UTType(filenameExtension: (name as NSString).pathExtension)
        let isImage = fileType?.conforms(to: .image) ?? false
        let kind: MediaItem.Kind = isImage ? .image : video != nil ? .video : .audio

        var metadata = MediaMetadata(duration: isImage ? .zero : frames(file.child("duration")?.text, rate) ?? .zero)
        if let characteristics = video?.child("samplecharacteristics") {
            metadata.naturalSize = CGSize(width: Double(characteristics.child("width")?.text ?? "") ?? 0,
                                          height: Double(characteristics.child("height")?.text ?? "") ?? 0)
            if !isImage { metadata.nominalFrameRate = 1 / rate.seconds }
        }
        if let audio, !isImage {
            metadata.audioChannelCount = Int(audio.child("channelcount")?.text ?? "") ?? 2
            metadata.audioSampleRate = Double(audio.descendant("samplecharacteristics", "samplerate")?.text ?? "") ?? 48000
        }
        return media.item(key: file["id"] ?? name, url: url, name: name, kind: kind, metadata: metadata)
    }

    // MARK: - Times

    /// Where a transition puts the cut between its clips: its middle,
    /// unless it's aligned to start or end there.
    private static func cut(of transition: MarkupElement, start: CMTime, end: CMTime) -> CMTime {
        switch transition.child("alignment")?.text.lowercased() {
        case "start", "start-black": start
        case "end", "end-black": end
        default: start + CMTimeMultiplyByRatio(end - start, multiplier: 1, divisor: 2)
        }
    }

    private static func frameDuration(of element: MarkupElement) -> CMTime {
        let rate = element.name == "rate" ? element : element.child("rate")
        let timebase = Int64(rate?.child("timebase")?.text ?? "") ?? 30
        return InterchangeTime.frameDuration(timebase: timebase, ntsc: rate?.child("ntsc")?.text.uppercased() == "TRUE")
    }

    /// A count of frames as a time; nil for none, or for -1, which stands
    /// for a time inside a transition.
    private func frames(_ text: String?, _ frameDuration: CMTime) -> CMTime? {
        guard let text, let count = Int64(text), count >= 0 else { return nil }
        return InterchangeTime.frames(count, frameDuration: frameDuration)
    }
}
