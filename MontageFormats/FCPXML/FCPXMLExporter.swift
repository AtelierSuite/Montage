import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine

/// Writes a project as FCPXML 1.11, which Final Cut Pro 10.6.6 and later
/// read.
///
/// Final Cut has no tracks, so the first video track becomes the primary
/// storyline, with gaps where it has none, running to the end of the
/// project. Every other track's clips are connected to it: video tracks on
/// lanes above, in order, and audio tracks on lanes below. Each connected
/// clip hangs off the storyline element it starts over, as do the
/// project's markers.
///
/// Times go onto the project's frames, as Final Cut expects cuts to.
struct FCPXMLExporter {
    static let version = "1.11"

    let project: Project
    let name: String
    let mediaResolver: MediaResolver

    private var frameDuration: CMTime { project.settings.frameDuration }

    func document() -> Data {
        var resources = Resources()
        let sequenceFormat = resources.add(format: [
            ("frameDuration", InterchangeTime.string(frameDuration)),
            ("width", Self.integer(project.settings.renderSize.width)),
            ("height", Self.integer(project.settings.renderSize.height)),
        ])
        let duration = conform(project.duration)

        let videoTracks = project.tracks.filter { $0.kind == .video }
        let audioTracks = project.tracks.filter { $0.kind == .audio }
        let primary = videoTracks.first

        // The primary storyline, gaps and all, remembering where each element
        // is so connected clips can be hung off it.
        var spine: [SpineElement] = []
        var cursor = CMTime.zero
        for clip in primary?.clips ?? [] {
            let range = conformed(clip.timelineRange)
            guard range.duration > .zero, range.start >= cursor else { continue }
            if range.start > cursor { spine.append(.gap(CMTimeRange(start: cursor, end: range.start))) }
            spine.append(.clip(clip, range))
            cursor = range.end
        }
        if cursor < duration || spine.isEmpty {
            spine.append(.gap(CMTimeRange(start: cursor, end: max(duration, cursor))))
        }

        var elements = spine.map { element(for: $0, lane: nil, resources: &resources) }
        let connected = videoTracks.dropFirst().enumerated().map { ($0.element, $0.offset + 1) }
            + audioTracks.enumerated().map { ($0.element, -($0.offset + 1)) }
        for (track, lane) in connected {
            // A connected clip can't be a gap, so what goes out as gaps is
            // left out instead.
            for clip in track.clips where !Self.isLeftOut(clip) {
                let range = conformed(clip.timelineRange)
                guard range.duration > .zero,
                      let index = spine.firstIndex(where: { $0.range.containsTime(range.start) }) else { continue }
                let parentStart = localStart(of: spine[index])
                let offset = parentStart + (range.start - spine[index].range.start)
                var child = clipElement(clip, range: range, lane: lane, resources: &resources)
                child.attributes.removeAll { $0.name == "offset" }
                child.attributes.insert(("offset", InterchangeTime.string(offset)), at: 0)
                elements[index].insertAnchored(child)
            }
        }
        // Final Cut's markers belong to clips, so the timeline's go on the
        // primary storyline's element under each, after what's connected
        // to it. One at the very end goes on the last frame.
        for marker in project.markers {
            let time = min(max(conform(marker.time), .zero), max(.zero, cursor - frameDuration))
            guard let index = spine.lastIndex(where: { $0.range.start <= time }) else { continue }
            let start = localStart(of: spine[index]) + (time - spine[index].range.start)
            elements[index].insertAnchored(MarkupElement("marker", [
                ("start", InterchangeTime.string(start)), ("duration", InterchangeTime.string(frameDuration)),
                ("value", marker.name),
            ]))
        }
        for index in elements.indices { elements[index].removeAnchorMarkers() }

        let sequence = MarkupElement("sequence", [
            ("format", sequenceFormat), ("duration", InterchangeTime.string(duration)), ("tcStart", "0s"),
            ("tcFormat", "NDF"), ("audioLayout", "stereo"), ("audioRate", "48k"),
        ], children: [MarkupElement("spine", children: elements)])
        let root = MarkupElement("fcpxml", [("version", Self.version)], children: [
            MarkupElement("resources", children: resources.elements),
            MarkupElement("library", children: [
                MarkupElement("event", [("name", name)], children: [
                    MarkupElement("project", [("name", name)], children: [sequence]),
                ]),
            ]),
        ])
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE fcpxml>\n\n" + root.xmlString()
        return Data(xml.utf8)
    }

    // MARK: - Storyline

    private enum SpineElement {
        case gap(CMTimeRange)
        case clip(Clip, CMTimeRange)

        var range: CMTimeRange {
            switch self {
            case .gap(let range), .clip(_, let range): range
            }
        }
    }

    /// A storyline element's own local time at its start, as its `start`
    /// is written: a still image's, and a gap's, is zero.
    private func localStart(of element: SpineElement) -> CMTime {
        guard case .clip(let clip, _) = element, let item = project.mediaItem(id: clip.mediaID),
              item.kind != .image else { return .zero }
        return conform(clip.sourceRange.start)
    }

    private func element(for spineElement: SpineElement, lane: Int?, resources: inout Resources) -> MarkupElement {
        switch spineElement {
        case .gap(let range):
            return MarkupElement("gap", [
                ("name", "Gap"), ("offset", InterchangeTime.string(range.start)), ("start", "0s"),
                ("duration", InterchangeTime.string(range.duration)),
            ])
        case .clip(let clip, let range):
            return clipElement(clip, range: range, lane: lane, resources: &resources)
        }
    }

    /// Whether a clip has nothing FCPXML can hold: a shape, or text with no
    /// words, which Final Cut would fill with its title's own. These go out
    /// as gaps, and are listed by `ProjectInterchange.clipsLeftOutOfFCPXML`
    /// for the export to report.
    static func isLeftOut(_ clip: Clip) -> Bool {
        switch clip.content {
        case .shape: true
        case .text(let text): text.string.isEmpty
        case .media, .image: false
        }
    }

    /// A clip, as an asset clip, a video element for a still image, or a
    /// title for text. What `isLeftOut` goes out as a gap.
    private func clipElement(_ clip: Clip, range: CMTimeRange, lane: Int?, resources: inout Resources) -> MarkupElement {
        if case .text(let text) = clip.content, !Self.isLeftOut(clip) {
            return titleElement(clip, text: text, range: range, lane: lane, resources: &resources)
        }
        guard let item = project.mediaItem(id: clip.mediaID) else {
            return MarkupElement("gap", [("offset", InterchangeTime.string(range.start)),
                                         ("duration", InterchangeTime.string(range.duration))])
        }
        let asset = resources.add(asset: item, url: url(for: item))
        let start = item.kind == .image ? .zero : conform(clip.sourceRange.start)
        let isImage = item.kind == .image
        let isAudioTrack = lane.map { $0 < 0 } ?? false
        var sourceEnable: String?
        if !isImage && item.kind != .audio {
            if isAudioTrack { sourceEnable = "audio" } else if clip.isAudioDetached && item.metadata.hasAudio { sourceEnable = "video" }
        }

        var attributes: [(String, String?)] = [
            ("ref", asset), ("offset", InterchangeTime.string(range.start)), ("name", (item.name as NSString).deletingPathExtension),
            ("start", InterchangeTime.string(start)), ("duration", InterchangeTime.string(range.duration)),
            ("lane", lane.map(String.init)),
        ]
        if !isImage {
            attributes.append(("srcEnable", sourceEnable))
            attributes.append(("tcFormat", "NDF"))
        }

        // Keyframes are timed in the element's local time, from `start`.
        let local: (CMTime) -> CMTime = { start + $0 }
        var children: [MarkupElement] = []
        if !isAudioTrack && item.kind != .audio {
            if let transform = transformElement(clip.transform, local: local) { children.append(transform) }
            if clip.opacity.isAnimated || clip.opacity.value != 1 {
                children.append(MarkupElement("adjust-blend", [("amount", Self.decimal(clip.opacity.value))],
                                              children: param("amount", clip.opacity, local: local) { Self.decimal($0) }))
            }
        }
        if !isImage && sourceEnable != "video" {
            let gain = clip.effects.lazy.filter(\.isEnabled).compactMap { effect -> Double? in
                if case .gain(let gain) = effect.kind { gain.decibels.value } else { nil }
            }.reduce(0, +)
            if clip.volume.isAnimated || clip.volume.value != 1 || gain != 0 {
                children.append(MarkupElement("adjust-volume", [("amount", Self.decibels(clip.volume.value, plus: gain))],
                                              children: param("amount", clip.volume, local: local) { Self.decibels($0, plus: gain) }))
            }
            if let pan = clip.effects.lazy.filter(\.isEnabled).compactMap({ effect -> Pan? in
                if case .pan(let pan) = effect.kind { pan } else { nil }
            }).first {
                children.append(MarkupElement("adjust-panner", [("amount", Self.decimal(pan.position.value * 100))],
                                              children: param("amount", pan.position, local: local) { Self.decimal($0 * 100) }))
            }
        }
        // Connected clips go here, between the settings and the effects.
        children.append(MarkupElement(Self.anchorMarker))
        let filters = clip.effects.compactMap { filterElement(for: $0, local: local, resources: &resources) }
        children += filters.filter { $0.name != "filter-audio" } + filters.filter { $0.name == "filter-audio" }

        return MarkupElement(isImage ? "video" : "asset-clip", attributes, children: children)
    }

    /// A text clip as an instance of Final Cut's Basic Title, with its words,
    /// their formatting, its transform, opacity and video effects.
    private func titleElement(_ clip: Clip, text: TextContent, range: CMTimeRange, lane: Int?, resources: inout Resources) -> MarkupElement {
        let effect = resources.add(effect: FCPXMLTitles.basicTitleName, uid: FCPXMLTitles.basicTitleUID)
        let words = FCPXMLTitles.textElements(for: text) { resources.nextTextStyleID() }
        let name = text.string.split(whereSeparator: \.isNewline).first.map(String.init) ?? FCPXMLTitles.basicTitleName
        let attributes: [(String, String?)] = [
            ("ref", effect), ("offset", InterchangeTime.string(range.start)), ("name", name), ("start", "0s"),
            ("duration", InterchangeTime.string(range.duration)), ("lane", lane.map(String.init)),
        ]
        // A title's local time starts at zero, as its keyframes do.
        let local: (CMTime) -> CMTime = { $0 }
        var children = [words.text]
        children += words.definitions
        if let transform = transformElement(clip.transform, local: local) { children.append(transform) }
        if clip.opacity.isAnimated || clip.opacity.value != 1 {
            children.append(MarkupElement("adjust-blend", [("amount", Self.decimal(clip.opacity.value))],
                                          children: param("amount", clip.opacity, local: local) { Self.decimal($0) }))
        }
        children.append(MarkupElement(Self.anchorMarker))
        children += clip.effects.filter(\.kind.isVideo).compactMap { filterElement(for: $0, local: local, resources: &resources) }
        return MarkupElement("title", attributes, children: children)
    }

    /// Where connected clips go among a clip's children; taken out once
    /// they're in.
    static let anchorMarker = "montage-anchors"

    private func transformElement(_ transform: ClipTransform, local: @escaping (CMTime) -> CMTime) -> MarkupElement? {
        guard transform != ClipTransform() else { return nil }
        let size = project.settings.renderSize
        let aspect = size.height > 0 ? size.width / size.height : 16 / 9
        func position(_ point: CGPoint) -> String {
            "\(Self.decimal((point.x - 0.5) * 100 * aspect)) \(Self.decimal((0.5 - point.y) * 100))"
        }
        let scale: (Double) -> String = { "\(Self.decimal($0)) \(Self.decimal($0))" }
        let rotation: (Double) -> String = { Self.decimal($0 == 0 ? 0 : -$0) }
        return MarkupElement("adjust-transform", [
            ("position", position(transform.position.value)), ("scale", scale(transform.scale.value)),
            ("rotation", rotation(transform.rotation.value)),
        ], children: param("position", transform.position, local: local, position)
            + param("scale", transform.scale, local: local, scale)
            + param("rotation", transform.rotation, local: local, rotation))
    }

    /// A setting's keyframes, as a `param` holding them; nothing if it has
    /// none.
    private func param<Value>(
        _ name: String, _ animatable: Animatable<Value>, local: (CMTime) -> CMTime, _ format: (Value) -> String
    ) -> [MarkupElement] {
        guard animatable.isAnimated else { return [] }
        let keyframes = animatable.keyframes.map { keyframe in
            MarkupElement("keyframe", [
                ("time", InterchangeTime.string(local(keyframe.time))), ("value", format(keyframe.value)),
                ("interp", Self.interp(keyframe.interpolation)),
            ])
        }
        return [MarkupElement("param", [("name", name)], children: [MarkupElement("keyframeAnimation", children: keyframes)])]
    }

    static func interp(_ interpolation: Interpolation) -> String? {
        switch interpolation {
        case .linear, .hold: nil
        case .easeIn: "easeIn"
        case .easeOut: "easeOut"
        case .easeInOut: "ease"
        // Final Cut has no curves of its own, so a curve goes out as the
        // easing it's closest to: slow to start where its first handle sits
        // under the straight line, slow to end where its second sits over it.
        case .bezier(let curve):
            switch (curve.y1 < curve.x1, curve.y2 > curve.x2) {
            case (true, true): "ease"
            case (true, false): "easeIn"
            case (false, true): "easeOut"
            case (false, false): nil
            }
        }
    }

    // MARK: - Effects

    /// An effect as a Final Cut filter: its built-in blur and pixellate for a
    /// mosaic, its Color Adjustments for colour correction, an effect
    /// brought from Final Cut as it was, and Montage's own for the rest, which Final Cut lists as missing but which come back
    /// into Montage whole. Gain and pan are clip settings in Final Cut, and
    /// effects from other formats are left out.
    private func filterElement(for effect: Effect, local: @escaping (CMTime) -> CMTime, resources: inout Resources) -> MarkupElement? {
        let enabled = effect.isEnabled ? nil : "0"
        switch effect.kind {
        case .gain, .pan:
            return nil
        case .unsupported(let unsupported):
            guard unsupported.format == InterchangeFormat.fcpxml.rawValue, let original = unsupported.original,
                  var filter = try? MarkupElement.parse(Data(original.utf8)) else { return nil }
            let ref = resources.add(effect: unsupported.name, uid: unsupported.identifier)
            // Kept as Final Cut wrote it, under this file's ID for the effect.
            filter.rewriteReferences(to: ref)
            return filter
        case .mosaic(let mosaic) where mosaic.style != .checkerboard:
            let isBlur = mosaic.style == .blur
            let ref = resources.add(
                effect: isBlur ? "Gaussian Blur" : "Pixellate",
                uid: isBlur ? EffectMapping.fcpGaussianBlurUID : EffectMapping.fcpPixellateUID
            )
            let width = project.settings.renderSize.width
            let amount = MarkupElement("param", [("name", "Amount"), ("value", Self.decimal(mosaic.scale.value * width))],
                                       children: param("Amount", mosaic.scale, local: local) { Self.decimal($0 * width) }
                                           .first?.children ?? [])
            return MarkupElement("filter-video", [("ref", ref), ("name", isBlur ? "Gaussian Blur" : "Pixellate"), ("enabled", enabled)],
                                 children: [amount])
        case .colorCorrection(let correction):
            // Final Cut's Color Adjustments, with the sliders it shares with
            // Montage, and Montage's own correction beside them for the rest.
            let ref = resources.add(effect: "Color Adjustments", uid: EffectMapping.fcpColorAdjustmentsUID)
            var children = [MarkupElement("data", [("key", "effectConfig")], text: EffectMapping.fcpColorAdjustmentsConfig)]
            if let data = EffectMapping.montageData(for: effect.kind) {
                children.append(MarkupElement("data", [("key", EffectMapping.montageDataKey)], text: data))
            }
            children += EffectMapping.fcpColorAdjustments(for: correction).map { slider in
                MarkupElement("param", [("name", slider.name), ("key", slider.key), ("value", Self.decimal(slider.value.value))],
                              children: param(slider.name, slider.value, local: local) { Self.decimal($0) }.first?.children ?? [])
            }
            return MarkupElement("filter-video", [("ref", ref), ("name", "Color Adjustments"), ("enabled", enabled)],
                                 children: children)
        default:
            guard let data = EffectMapping.montageData(for: effect.kind) else { return nil }
            let type = Self.typeName(effect.kind)
            let ref = resources.add(effect: "Montage \(type)", uid: EffectMapping.montageUIDPrefix + type)
            return MarkupElement(effect.kind.isVideo ? "filter-video" : "filter-audio",
                                 [("ref", ref), ("name", "Montage \(type)"), ("enabled", enabled)],
                                 children: [MarkupElement("data", [("key", "effectConfig")], text: data)])
        }
    }

    private static func typeName(_ kind: Effect.Kind) -> String {
        let data = (try? JSONEncoder().encode(kind)) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return object?["type"] as? String ?? "effect"
    }

    // MARK: - Media

    /// The file Final Cut should find the media at: where it is, or failing
    /// that its place in the project's package, relative to the project.
    private func url(for item: MediaItem) -> String {
        if let url = mediaResolver.url(for: item) { return url.absoluteString }
        if case .package(let path) = item.location {
            return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        }
        return item.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? item.name
    }

    private struct Resources {
        private(set) var elements: [MarkupElement] = []
        private var assets: [MediaItem.ID: String] = [:]
        private var effects: [String: String] = [:]
        private var formats: [String: String] = [:]
        private var textStyleCount = 0

        private mutating func nextID() -> String { "r\(elements.count + 1)" }

        /// A new ID for a title's text style, which the whole document's
        /// titles share.
        mutating func nextTextStyleID() -> String {
            textStyleCount += 1
            return "ts\(textStyleCount)"
        }

        mutating func add(format attributes: [(String, String?)]) -> String {
            let key = attributes.map { "\($0.0)=\($0.1 ?? "")" }.joined(separator: ",")
            if let id = formats[key] { return id }
            let id = nextID()
            elements.append(MarkupElement("format", [("id", id)] + attributes))
            formats[key] = id
            return id
        }

        mutating func add(effect name: String, uid: String) -> String {
            if let id = effects[uid] { return id }
            let id = nextID()
            elements.append(MarkupElement("effect", [("id", id), ("name", name), ("uid", uid)]))
            effects[uid] = id
            return id
        }

        mutating func add(asset item: MediaItem, url: String) -> String {
            if let id = assets[item.id] { return id }
            let metadata = item.metadata
            let size = metadata.presentationSize
            var format: String?
            if metadata.hasVideo {
                format = add(format: [
                    ("frameDuration", item.kind == .image || metadata.nominalFrameRate <= 0 ? nil
                        : InterchangeTime.string(FCPXMLExporter.frameDuration(forRate: metadata.nominalFrameRate))),
                    ("width", FCPXMLExporter.integer(size.width)), ("height", FCPXMLExporter.integer(size.height)),
                ])
            }
            let id = nextID()
            let hasAudio = metadata.hasAudio && item.kind != .image
            elements.append(MarkupElement("asset", [
                ("id", id), ("name", (item.name as NSString).deletingPathExtension), ("start", "0s"),
                ("duration", InterchangeTime.string(metadata.duration)),
                ("hasVideo", metadata.hasVideo ? "1" : nil), ("format", format),
                ("hasAudio", hasAudio ? "1" : nil), ("audioSources", hasAudio ? "1" : nil),
                ("audioChannels", hasAudio ? String(metadata.audioChannelCount) : nil),
                ("audioRate", hasAudio ? Self.integer(metadata.audioSampleRate) : nil),
            ], children: [MarkupElement("media-rep", [("kind", "original-media"), ("src", url)])]))
            assets[item.id] = id
            return id
        }

        private static func integer(_ value: Double) -> String { String(Int(value.rounded())) }
    }

    // MARK: - Values

    /// A frame rate as the frame length Final Cut names it by: NTSC rates
    /// as thousand-and-first fractions.
    static func frameDuration(forRate rate: Double) -> CMTime {
        let rounded = rate.rounded()
        if abs(rate - rounded * 1000 / 1001) < 0.005 && abs(rate - rounded) > 0.005 {
            return InterchangeTime.time(1001, over: Int64(rounded) * 1000)
        }
        return InterchangeTime.time(1, over: max(1, Int64(rounded)))
    }

    private func conform(_ time: CMTime) -> CMTime {
        InterchangeTime.conformed(time, to: frameDuration)
    }

    private func conformed(_ range: CMTimeRange) -> CMTimeRange {
        CMTimeRange(start: conform(range.start), end: conform(range.end))
    }

    static func integer(_ value: CGFloat) -> String { String(Int(value.rounded())) }

    /// A number without trailing zeros, to a millionth.
    static func decimal(_ value: Double) -> String {
        let rounded = (value * 1_000_000).rounded() / 1_000_000
        if rounded == rounded.rounded() && abs(rounded) < 1e15 { return String(Int64(rounded)) }
        return String(format: "%.6f", rounded).replacingOccurrences(of: "0+$", with: "", options: .regularExpression)
    }

    /// A level as Final Cut's decibels, with silence as its lowest level.
    static func decibels(_ linear: Double, plus gain: Double = 0) -> String {
        let decibels = linear > 0 ? 20 * log10(linear) + gain : -96
        return "\(decimal(max(-96, decibels)))dB"
    }
}

extension MarkupElement {
    /// Puts connected clips in a clip's place for them, or after its
    /// settings in a gap.
    mutating func insertAnchored(_ child: MarkupElement) {
        if let index = children.firstIndex(where: { $0.name == FCPXMLExporter.anchorMarker }) {
            children.insert(child, at: index)
        } else {
            children.append(child)
        }
    }

    /// Takes out the place kept for connected clips, here and below.
    mutating func removeAnchorMarkers() {
        children.removeAll { $0.name == FCPXMLExporter.anchorMarker }
        for index in children.indices { children[index].removeAnchorMarkers() }
    }

    /// Points a filter, and any filters inside it, at an effect resource.
    mutating func rewriteReferences(to ref: String) {
        if let index = attributes.firstIndex(where: { $0.name == "ref" }) { attributes[index].value = ref }
        for index in children.indices where children[index].name.hasPrefix("filter-") {
            children[index].rewriteReferences(to: ref)
        }
    }
}
