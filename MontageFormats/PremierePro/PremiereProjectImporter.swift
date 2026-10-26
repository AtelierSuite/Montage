import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

/// Reads a sequence from a Premiere Pro project (`.prproj`) into the same
/// model the Final Cut Pro 7 XML importer makes, so both share the tracks'
/// assembly and the import report.
///
/// The way through a project's objects, as Premiere 2020 and later write it:
///
///     Sequence ─ TrackGroups ─▶ VideoTrackGroup / AudioTrackGroup
///         (FrameRate in ticks per frame, FrameRect)
///       ─ Tracks ─▶ VideoClipTrack / AudioClipTrack
///       ─ ClipItems ─▶ VideoClipTrackItem (Start, End on the timeline)
///           ─ SubClip ─▶ VideoClip (InPoint, OutPoint in the media)
///               ─ Source ─▶ VideoMediaSource ─ Media ─▶ Media (paths)
///                         or VideoSequenceSource ─▶ a nested Sequence
///           ─ ComponentOwner ─▶ VideoComponentChain ─▶ components and
///               their parameters, keyframes included
///       ─ TransitionItems ─▶ VideoTransitionTrackItem
///     Sequence ─ MarkerOwner ─▶ Markers ─▶ Marker (DVAMarker JSON)
///
/// Premiere only writes the components a clip's settings were changed in:
/// untouched motion, opacity and volume aren't in the file at all.
struct PremiereProjectImporter {
    private let graph: PremiereObjectGraph
    private let baseURL: URL?
    private var media = ImportedMedia()
    private var assembler = TimelineAssembler()
    private var report = ImportReport(format: .prproj)
    private var settings = ProjectSettings()
    /// The track items made part of another clip, by object ID.
    private var merged: Set<String> = []
    /// The sequences being read, by UID, so one nested in itself stops.
    private var nesting: Set<String> = []

    /// Reads a project, gzipped as Premiere saves it or not.
    static func read(
        _ data: Data, baseURL: URL?, versions: ClosedRange<Int> = PremiereProject.supportedVersions
    ) throws -> ImportedProject {
        let graph = try PremiereObjectGraph.read(data) { versions.contains($0) }
        var importer = PremiereProjectImporter(graph: graph, baseURL: baseURL)
        return try importer.run()
    }

    private init(graph: PremiereObjectGraph, baseURL: URL?) {
        self.graph = graph
        self.baseURL = baseURL
    }

    private mutating func run() throws -> ImportedProject {
        // As with Final Cut 7 XML, the first sequence is the one imported,
        // though one with nothing on it is passed over: a project lists its
        // sequences in no order the user chose. Those only used nested in
        // others aren't counted as others.
        let nested = nestedSequenceUIDs()
        let topLevel = graph.sequences.filter { !nested.contains($0["ObjectUID"] ?? "") }
        let candidates = topLevel.isEmpty ? graph.sequences : topLevel
        guard let sequence = candidates.first(where: hasClips) ?? candidates.first else { throw InterchangeError.noTimeline }
        if candidates.count > 1 { report.add(.otherTimelines(count: candidates.count - 1)) }

        if let video = trackGroups(of: sequence).first(where: { $0.kind == .video })?.group {
            if let rate = PremiereProject.ticks(video.descendant("TrackGroup", "FrameRate")?.text), rate > 0 {
                settings.frameDuration = PremiereProject.frameDuration(ticksPerFrame: rate)
            }
            if let size = Self.size(video.child("FrameRect")?.text) { settings.renderSize = size }
        }
        importSequence(sequence, placement: Placement(base: .zero, origin: .zero, window: nil), lane: 0,
                       kinds: [.video, .audio])

        var project = Project(settings: settings, media: media.items)
        project.tracks = assembler.tracks(report: &report)
        for marker in markers(sequence.descendant("MarkerOwner", "Markers")) {
            project.addMarker(at: PremiereProject.time(marker.ticks), name: marker.name)
        }
        return ImportedProject(
            project: project, report: report, name: sequence.child("Name")?.text, mediaSources: media.sources
        )
    }

    // MARK: - Sequences

    private struct Placement {
        /// The timeline time of `origin`, a time in the sequence.
        var base: CMTime
        var origin: CMTime
        /// The part of the timeline a nested sequence shows.
        var window: CMTimeRange?

        func timeline(_ time: CMTime) -> CMTime { base + (time - origin) }
    }

    private func trackGroups(of sequence: MarkupElement) -> [(kind: Track.Kind, group: MarkupElement)] {
        (sequence.child("TrackGroups")?.children("TrackGroup") ?? []).compactMap { entry in
            guard let group = graph.resolve(entry.child("Second")) else { return nil }
            switch (group.name, entry.child("First")?.text) {
            case ("VideoTrackGroup", _), (_, Self.videoMediaType): return (.video, group)
            case ("AudioTrackGroup", _), (_, Self.audioMediaType): return (.audio, group)
            default: return nil
            }
        }
    }

    private static let videoMediaType = "228cda18-3625-4d2d-951e-348879e4ed93"
    private static let audioMediaType = "80b8e3d5-6dca-4195-aefb-cb5f407ab009"

    /// A sequence's tracks of the given kinds, video tracks bottom first
    /// counting up from `lane` and audio tracks counting down from it.
    private mutating func importSequence(_ sequence: MarkupElement, placement: Placement, lane: Int, kinds: Set<Track.Kind>) {
        let uid = sequence["ObjectUID"] ?? ""
        guard !nesting.contains(uid) else { return }
        nesting.insert(uid)
        defer { nesting.remove(uid) }

        let groups = trackGroups(of: sequence)
        let tracks = groups.map { group in
            (group.kind, (group.group.descendant("TrackGroup", "Tracks")?.children("Track") ?? []).compactMap(graph.resolve))
        }
        let audioItems = tracks.filter { $0.0 == .audio }.flatMap { $0.1 }.flatMap { clipItems(of: $0) }
        // Pictures first, so the sound in step with them is taken into their
        // clips before the audio tracks are read, whichever order the
        // groups are in.
        let ordered = tracks.filter { $0.0 == .video } + tracks.filter { $0.0 == .audio }
        for (kind, kindTracks) in ordered where kinds.contains(kind) {
            for (index, track) in kindTracks.enumerated() {
                importTrack(track, kind: kind, lane: kind == .video ? lane + index : lane - index, placement: placement,
                            audioItems: kind == .video ? audioItems : [])
            }
        }
    }

    private func hasClips(_ sequence: MarkupElement) -> Bool {
        trackGroups(of: sequence).contains { group in
            (group.group.descendant("TrackGroup", "Tracks")?.children("Track") ?? []).compactMap(graph.resolve).contains {
                $0.descendant("ClipTrack", "ClipItems", "TrackItems")?.child("TrackItem") != nil
            }
        }
    }

    /// The sequences nested in clips on another sequence's tracks.
    private func nestedSequenceUIDs() -> Set<String> {
        Set(graph.objects.filter { $0.name.hasSuffix("ClipTrackItem") }.compactMap { object in
            trackItem(object)?.source?.descendant("SequenceSource", "Sequence")?["ObjectURef"]
        })
    }

    // MARK: - Tracks

    private func clipItems(of track: MarkupElement) -> [TrackItem] {
        (track.descendant("ClipTrack", "ClipItems", "TrackItems")?.children("TrackItem") ?? [])
            .compactMap(graph.resolve).compactMap(trackItem)
    }

    private mutating func importTrack(
        _ track: MarkupElement, kind: Track.Kind, lane: Int, placement: Placement, audioItems: [TrackItem]
    ) {
        let isMuted = track.descendant("ClipTrack", "Track", "IsMuted")?.text == "true"
        for reference in track.descendant("ClipTrack", "TransitionItems", "TrackItems")?.children("TrackItem") ?? [] {
            guard let transition = graph.resolve(reference)?.child("TransitionTrackItem") else { continue }
            let start = PremiereProject.ticks(transition.descendant("TrackItem", "Start")?.text) ?? 0
            let end = PremiereProject.ticks(transition.descendant("TrackItem", "End")?.text) ?? start
            let range = CMTimeRange(start: placement.timeline(PremiereProject.time(start)),
                                    end: placement.timeline(PremiereProject.time(end)))
            assembler.addTransition(range, lane: lane)
            let name = transition.child("DisplayName")?.text ?? transition.child("MatchName")?.text ?? ""
            report.add(.transition(name: name.isEmpty ? "Transition" : name), time: range.start)
        }
        for item in clipItems(of: track) {
            guard !isMuted else {
                report.add(.disabledClip, clipName: item.name, time: placement.timeline(PremiereProject.time(item.start)))
                continue
            }
            importClip(item, kind: kind, lane: lane, placement: placement, audioItems: audioItems)
        }
    }

    // MARK: - Clips

    /// A clip on a track, with what the importer reads of it gathered from
    /// the objects it's spread across.
    private struct TrackItem {
        var id: String
        var object: MarkupElement
        var name: String?
        /// On the sequence's timeline, in ticks.
        var start: Int64
        var end: Int64
        /// In the media, in ticks, at normal speed.
        var inPoint: Int64
        var outPoint: Int64
        var speed: Double
        /// The clip's core: its source, in and out points and markers.
        var clip: MarkupElement?
        var source: MarkupElement?
        var isDisabled: Bool

        var mediaUID: String? { source?.descendant("MediaSource", "Media")?["ObjectURef"] }
    }

    private func trackItem(_ object: MarkupElement) -> TrackItem? {
        guard let core = object.child("ClipTrackItem") else { return nil }
        // Premiere leaves out a start of zero.
        let start = PremiereProject.ticks(core.descendant("TrackItem", "Start")?.text) ?? 0
        let end = PremiereProject.ticks(core.descendant("TrackItem", "End")?.text) ?? start
        let subClip = graph.resolve(core.child("SubClip"))
        let clip = graph.resolve(subClip?.child("Clip"))?.child("Clip")
        let speed = clip?.child("PlaybackSpeed").flatMap { PremiereProject.number($0.text) } ?? 1
        // A clip's speed is left out at normal speed; when it's changed, its
        // in and out points are written as if at that speed.
        func source(_ name: String) -> Int64 {
            let raw = PremiereProject.ticks(clip?.child(name)?.text) ?? 0
            guard speed != 0, speed != 1 else { return raw }
            let scaled = Double(raw) / abs(speed)
            return scaled.isFinite && abs(scaled) < 9e18 ? Int64(scaled) : raw
        }
        return TrackItem(
            id: object["ObjectID"] ?? object["ObjectUID"] ?? UUID().uuidString, object: object,
            name: subClip?.child("Name")?.text, start: start, end: end,
            inPoint: source("InPoint"), outPoint: source("OutPoint"), speed: speed, clip: clip,
            source: graph.resolve(clip?.child("Source")),
            isDisabled: core.child("IsMuted")?.text == "true"
        )
    }

    private mutating func importClip(
        _ item: TrackItem, kind: Track.Kind, lane: Int, placement: Placement, audioItems: [TrackItem]
    ) {
        guard !merged.contains(item.id) else { return }
        // Past what a count of ticks can hold, the times are nonsense.
        let (length, overflow) = item.end.subtractingReportingOverflow(item.start)
        guard !overflow, length > 0, !item.inPoint.addingReportingOverflow(length).overflow else { return }
        let duration = PremiereProject.time(length)
        let sourceIn = PremiereProject.time(item.inPoint)
        let timelineStart = placement.timeline(PremiereProject.time(item.start))
        let components = components(of: item)

        // A clip's markers are its media's, wherever they fall; only those
        // within the part used are on the timeline.
        for marker in markers(item.clip?.descendant("MarkerOwner", "Markers"))
        where marker.ticks >= item.inPoint && marker.ticks < item.inPoint + length {
            report.add(.marker(name: marker.name), clipName: item.name,
                       time: timelineStart + (PremiereProject.time(marker.ticks) - sourceIn))
        }
        if item.isDisabled {
            report.add(.disabledClip, clipName: item.name, time: timelineStart)
            return
        }
        if abs(item.speed - 1) > 0.0001 || item.clip?.child("TimeRemapping") != nil {
            report.add(.speedChange, clipName: item.name, time: timelineStart)
        }
        let clipRange = CMTimeRange(start: timelineStart, duration: duration)
        let window = placement.window.map { $0.intersection(clipRange) } ?? clipRange

        // A nested sequence: its clips, played from the clip's in point.
        if let nested = graph.resolve(item.source?.descendant("SequenceSource", "Sequence")) {
            if !components.isEmpty { report.add(.nestedSettings, clipName: item.name, time: timelineStart) }
            importSequence(nested, placement: Placement(base: timelineStart, origin: sourceIn, window: window), lane: lane,
                           kinds: [kind])
            return
        }
        if item.source?.name.localizedCaseInsensitiveContains("MultiCam") == true {
            report.add(.setting(name: "Multicam"), clipName: item.name, time: timelineStart)
            return
        }
        // Titles, graphics, adjustment layers and other generated media
        // have no file behind them.
        guard let mediaObject = graph.resolve(item.source?.descendant("MediaSource", "Media")),
              Self.hasFile(mediaObject) else {
            let generator = graph.resolve(item.source?.descendant("MediaSource", "Media"))?.child("Title")?.text
            report.add(.generator(name: generator ?? item.name ?? ""), clipName: item.name, time: timelineStart)
            return
        }

        let mediaItem = mediaItem(for: mediaObject)
        let name = item.name ?? mediaItem.name
        var clip = Clip(
            content: mediaItem.content,
            sourceRange: CMTimeRange(start: mediaItem.kind == .image ? .zero : sourceIn, duration: duration),
            timelineStart: timelineStart
        )
        var settingsFrom = [components]

        if kind == .video, mediaItem.kind != .audio {
            // The sound in step with this picture, if it's on the timeline.
            let inStep = audioItems.filter {
                $0.mediaUID == item.mediaUID && $0.start == item.start && $0.end == item.end
                    && $0.inPoint == item.inPoint && !$0.isDisabled
            }
            if let first = inStep.first {
                merged.formUnion(inStep.map(\.id))
                settingsFrom.append(self.components(of: first))
            } else if mediaItem.metadata.hasAudio {
                clip.isAudioDetached = true
            }
        } else if kind == .audio {
            // A file's channels on several tracks are one clip in Montage,
            // which plays the file's sound whole.
            merged.insert(item.id)
            merged.formUnion(audioItems.filter {
                $0.mediaUID == item.mediaUID && $0.start == item.start && $0.inPoint == item.inPoint
            }.map(\.id))
        }

        // Keyframes are timed in the media, as in and out points are: in
        // real projects a fade's last keyframe falls on the clip's out point
        // in the media, and a still's keyframes an hour in, with its in point.
        let toClip: (Int64) -> CMTime = { PremiereProject.time($0) - sourceIn }
        for components in settingsFrom {
            apply(components, to: &clip, item: mediaItem, toClip: toClip, clipName: name)
        }
        if let trimmed = clip.trimmed(to: window) {
            assembler.add(trimmed, kind: mediaItem.kind == .audio ? .audio : kind, lane: lane, name: name)
        }
    }

    // MARK: - Components

    /// One of a clip's effects, or the intrinsic motion, opacity or volume.
    private struct Component {
        var displayName: String
        var matchName: String
        var isEnabled: Bool
        var isVideo: Bool
        var parameters: [MarkupElement]

        /// A parameter by its name, or by its ID where Premiere leaves it
        /// unnamed, as 25.x does Motion's Uniform Scale.
        func parameter(_ name: String, id: String? = nil) -> MarkupElement? {
            parameters.first { $0.child("Name")?.text.caseInsensitiveCompare(name) == .orderedSame }
                ?? id.flatMap { id in
                    parameters.first {
                        $0.child("ParameterID")?.text == id && ($0.child("Name")?.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                    }
                }
        }
    }

    private func components(of item: TrackItem) -> [Component] {
        let chain = graph.resolve(item.object.descendant("ClipTrackItem", "ComponentOwner", "Components"))
        var components = (chain?.descendant("ComponentChain", "Components")?.children("Component") ?? []).compactMap { reference -> Component? in
            guard let object = graph.resolve(reference) else { return nil }
            // Audio components are a level deeper than video ones.
            let isVideo = object.child("Component") != nil
            guard let inner = object.child("Component") ?? object.descendant("AudioComponent", "Component") else { return nil }
            let displayName = inner.child("DisplayName")?.text ?? ""
            return Component(
                displayName: displayName,
                matchName: object.child("MatchName")?.text ?? object.child("FilterMatchName")?.text ?? displayName,
                isEnabled: inner.child("Bypass")?.text != "true",
                isVideo: isVideo,
                parameters: (inner.child("Params")?.children("Param") ?? []).compactMap(graph.resolve)
            )
        }
        // CS6 keeps a clip's panner beside its components, as a
        // MonoToStereo or StereoToStereo PanProcessor every audio clip has.
        // Only one moved off centre is taken, so the rest add nothing.
        if let panner = graph.resolve(item.object.child("Panner")), panner.name.hasSuffix("PanProcessor"),
           let inner = panner.descendant("PanProcessor", "AudioComponent", "Component") {
            let parameters = (inner.child("Params")?.children("Param") ?? []).compactMap(graph.resolve)
            let isOffCentre = parameters.contains { parameter in
                let name = parameter.child("Name")?.text
                guard name == "Pan" || name == "Balance" else { return false }
                return PremiereKeyframes.isAnimated(parameter)
                    || PremiereKeyframes.value(of: parameter).flatMap(PremiereProject.number).map { abs($0 - 0.5) > 0.0001 } == true
            }
            if isOffCentre {
                components.append(Component(
                    displayName: "Panner", matchName: panner.name, isEnabled: inner.child("Bypass")?.text != "true",
                    isVideo: false, parameters: parameters
                ))
            }
        }
        return components
    }

    /// Premiere's audio levels are written as gain scaled to the fader's
    /// range, which tops out at +15 dB: 1 is +15 dB, and unity gain, 0 dB,
    /// is 10^(-15/20), the level every untouched clip has. A level set to
    /// -20 dB is written as a tenth of that.
    static let unityLevel = pow(10, -15.0 / 20)

    private mutating func apply(
        _ components: [Component], to clip: inout Clip, item mediaItem: MediaItem, toClip: @escaping (Int64) -> CMTime,
        clipName: String
    ) {
        for component in components {
            let lowerMatch = component.matchName.lowercased()
            let lowerName = component.displayName.lowercased()
            func number(_ name: String) -> Animatable<Double>? {
                component.parameter(name).flatMap { PremiereKeyframes.animatable($0, toClip: toClip, PremiereKeyframes.number) }
            }

            if lowerMatch == "ae.adbe motion" || (component.isVideo && lowerName == "motion") {
                guard component.isEnabled else { continue }
                applyMotion(component, to: &clip, item: mediaItem, toClip: toClip, clipName: clipName)
            } else if lowerMatch == "ae.adbe opacity" || (component.isVideo && lowerName == "opacity") {
                guard component.isEnabled, let opacity = number("Opacity") else { continue }
                clip.opacity = opacity.mapped { max(0, min(1, $0 / 100)) }
            } else if lowerMatch.hasPrefix("internal volume") || (!component.isVideo && lowerName == "volume") {
                let bypassed = component.parameter("Bypass").flatMap { PremiereKeyframes.value(of: $0) } == "true"
                guard component.isEnabled, !bypassed, let level = number("Level") else { continue }
                clip.volume = level.mapped { max(0, $0 / Self.unityLevel) }
            } else if !component.isVideo, lowerName == "panner" || lowerName == "pan" || lowerMatch.contains("panner") {
                // Mono clips' Pan and stereo clips' Balance run from 0, full
                // left, through 0.5, centred, to 1, full right, as a mixed
                // feature's levels show, whatever `IsInverted` says: that's
                // only how the timeline draws its rubber band.
                let bypassed = component.parameter("Bypass").flatMap { PremiereKeyframes.value(of: $0) } == "true"
                guard let balance = number("Balance") ?? number("Pan"),
                      balance.isAnimated || abs(balance.value - 0.5) > 0.0001 else { continue }
                // Only a mono or stereo clip panned into stereo is known to
                // work so; surround, 16-channel and adaptive panners aren't.
                if lowerMatch.hasSuffix("panprocessor"),
                   !["monotostereopanprocessor", "stereotostereopanprocessor"].contains(lowerMatch) {
                    report.add(.setting(name: "Pan"), clipName: clipName, time: clip.timelineStart)
                    continue
                }
                var pan = Pan()
                pan.position = balance.mapped { max(-1, min(1, 2 * $0 - 1)) }
                clip.effects.append(Effect(isEnabled: component.isEnabled && !bypassed, .pan(pan)))
            } else if !component.isVideo, lowerName.contains("channel volume") || lowerMatch.contains("channel volume") {
                // Only the named channels: Premiere 24 and later write
                // unnamed ones beyond a stereo clip's two, some at zero.
                let isChanged = component.parameters.contains { parameter in
                    let name = parameter.child("Name")?.text.lowercased() ?? ""
                    guard !name.isEmpty, name != "bypass", name != "mute",
                          let level = PremiereKeyframes.animatable(parameter, toClip: toClip, PremiereKeyframes.number) else {
                        return false
                    }
                    return level.isAnimated || abs(level.value - Self.unityLevel) > 0.0001
                }
                if isChanged {
                    report.add(.setting(name: component.displayName.isEmpty ? "Channel Volume" : component.displayName),
                               clipName: clipName, time: clip.timelineStart)
                }
            } else {
                let lookup = ImportedParameters { number($0) }
                if let kind = EffectMapping.xmeml(id: component.matchName, name: component.displayName, parameters: lookup,
                                                  frameWidth: settings.renderSize.width) {
                    clip.effects.append(Effect(isEnabled: component.isEnabled, kind))
                    continue
                }
                let name = Self.effectName(displayName: component.displayName, matchName: component.matchName,
                                           isVideo: component.isVideo)
                report.add(.unsupportedEffect(name: name), clipName: clipName, time: clip.timelineStart)
                clip.effects.append(Effect(isEnabled: false, .unsupported(UnsupportedEffect(
                    format: InterchangeFormat.prproj.rawValue, identifier: component.matchName, name: name,
                    isVideo: component.isVideo,
                    parameters: component.parameters.map { parameter in
                        .init(name: parameter.child("Name")?.text ?? "", key: parameter.child("ParameterID")?.text,
                              value: PremiereKeyframes.value(of: parameter),
                              isAnimated: PremiereKeyframes.isAnimated(parameter))
                    }
                ))))
            }
        }
    }

    /// The name to show for an effect: the one Premiere showed, else its
    /// match name, unless that's only a plug-in's UUID, as a third-party
    /// audio plug-in's can be, which says nothing to the user.
    static func effectName(displayName: String, matchName: String, isVideo: Bool) -> String {
        if !displayName.isEmpty { return displayName }
        if !matchName.isEmpty, UUID(uuidString: matchName) == nil { return matchName }
        return isVideo ? String(localized: "PremiereProject.UnnamedVideoEffect", bundle: #bundle)
            : String(localized: "PremiereProject.UnnamedAudioEffect", bundle: #bundle)
    }

    /// Motion: the position as a fraction of the sequence's frame from its
    /// top left, the anchor point as a fraction of the media's picture,
    /// scale in percent of the media's own size, rotation clockwise in
    /// degrees about the anchor point.
    private mutating func applyMotion(
        _ component: Component, to clip: inout Clip, item: MediaItem, toClip: (Int64) -> CMTime, clipName: String
    ) {
        func number(_ name: String) -> Animatable<Double>? {
            component.parameter(name).flatMap { PremiereKeyframes.animatable($0, toClip: toClip, PremiereKeyframes.number) }
        }
        func point(_ name: String) -> Animatable<CGPoint>? {
            component.parameter(name).flatMap { PremiereKeyframes.animatable($0, toClip: toClip, PremiereKeyframes.point) }
        }
        // Montage's pictures start fitted to the frame.
        let media = item.metadata.presentationSize
        let frame = settings.renderSize
        let fit = media.width > 0 && media.height > 0 ? min(frame.width / media.width, frame.height / media.height) : 1
        let isUniform = component.parameter("Uniform Scale", id: "4").flatMap { PremiereKeyframes.value(of: $0) } != "false"
        if let scale = number("Scale") {
            clip.transform.scale = scale.mapped { $0 / 100 / fit }
            if !isUniform, let width = number("Scale Width"), width.isAnimated || abs(width.value - scale.value) > 0.001 {
                report.add(.uneven(name: "Scale"), clipName: clipName, time: clip.timelineStart)
            }
        }
        let rotation = number("Rotation")
        if let rotation { clip.transform.rotation = rotation }
        // Position is where the anchor point lands, as a fraction of the
        // sequence's frame whatever the media's size: a 2025 project has
        // 3888×2592 stills in a 1080p sequence at x = 1450/1920.
        let position = point("Position")
        if let position { clip.transform.position = position }
        if let anchor = point("Anchor Point"), anchor.isAnimated || anchor.value != CGPoint(x: 0.5, y: 0.5) {
            // The anchor point is a fraction of the media's own picture.
            // Montage places and turns a picture by its centre, which sits
            // a fixed way off the anchor while the anchor, scale and
            // rotation hold still: Premiere's own tutorial project puts a
            // 500 px still's anchor on its corner, 0:1, and so its centre
            // on the frame's.
            let height = number("Scale")
            let width = isUniform ? height : number("Scale Width")
            let holdsStill = !anchor.isAnimated && !(rotation?.isAnimated ?? false)
                && !(height?.isAnimated ?? false) && !(width?.isAnimated ?? false)
            if holdsStill, media.width > 0, media.height > 0, frame.width > 0, frame.height > 0 {
                let across = (0.5 - anchor.value.x) * media.width * (width?.value ?? 100) / 100
                let down = (0.5 - anchor.value.y) * media.height * (height?.value ?? 100) / 100
                let angle = (rotation?.value ?? 0) * .pi / 180
                let dx = (across * cos(angle) - down * sin(angle)) / frame.width
                let dy = (across * sin(angle) + down * cos(angle)) / frame.height
                let moved = { (point: CGPoint) in CGPoint(x: point.x + dx, y: point.y + dy) }
                let placed = position ?? Animatable(CGPoint(x: 0.5, y: 0.5))
                clip.transform.position = Animatable(moved(placed.value), keyframes: placed.keyframes.map {
                    Keyframe(time: $0.time, value: moved($0.value), interpolation: $0.interpolation)
                })
            } else {
                report.add(.setting(name: "Anchor point"), clipName: clipName, time: clip.timelineStart)
            }
        }
        // Recent releases have crop in Motion, in percent of each edge.
        let crops = ["Crop Left", "Crop Top", "Crop Right", "Crop Bottom"].compactMap(number)
        if crops.contains(where: { $0.isAnimated || $0.value != 0 }) {
            report.add(.setting(name: "Crop"), clipName: clipName, time: clip.timelineStart)
        }
    }

    // MARK: - Markers

    private struct MarkerInfo {
        var ticks: Int64
        var name: String
    }

    /// The markers in a `Markers` collection, from each one's DVAMarker
    /// JSON: `{"DVAMarker":{"mName":"…","mStartTime":{"ticks":…},…}}`.
    private func markers(_ reference: MarkupElement?) -> [MarkerInfo] {
        let entries = graph.resolve(reference)?.child("Markers")?.children("Marker") ?? []
        return entries.compactMap { entry in
            guard let json = graph.resolve(entry.child("Second"))?.child("DVAMarker")?.text,
                  let root = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                  let marker = root["DVAMarker"] as? [String: Any] else { return nil }
            let start = (marker["mStartTime"] as? [String: Any])?["ticks"]
            let ticks = (start as? NSNumber)?.int64Value ?? (start as? String).flatMap { Int64($0) } ?? 0
            return MarkerInfo(ticks: ticks, name: marker["mName"] as? String ?? "")
        }
    }

    // MARK: - Media

    /// Whether media is a file Montage can play. Generated media, such as
    /// a Graphic or a color matte, has no file key, and where it has a
    /// "path" at all it's a number. An After Effects composition linked in
    /// has a path, but to a project rather than to media.
    private static func hasFile(_ media: MarkupElement) -> Bool {
        let paths = ["ActualMediaFilePath", "FilePath", "RelativePath"].compactMap { media.child($0)?.text }.filter { !$0.isEmpty }
        let hasKey = !(media.child("FileKey")?.text.isEmpty ?? true)
        guard let path = paths.first, hasKey || paths.contains(where: { $0.contains("/") || $0.contains("\\") }) else {
            return false
        }
        let fileName = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
        return !["aep", "aepx", "prproj"].contains((fileName as NSString).pathExtension.lowercased())
    }

    private mutating func mediaItem(for object: MarkupElement) -> MediaItem {
        let url = Self.url(of: object, relativeTo: baseURL)
        let path = object.child("ActualMediaFilePath")?.text ?? object.child("FilePath")?.text ?? ""
        // Paths may be Windows ones, with backslashes.
        let fileName = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init)
        let name = object.child("Title")?.text ?? fileName ?? url?.lastPathComponent ?? "Media"
        let video = graph.resolve(object.child("VideoStream"))
        let audio = graph.resolve(object.child("AudioStream"))
        let fileType = UTType(filenameExtension: ((fileName ?? name) as NSString).pathExtension)
        let isImage = fileType?.conforms(to: .image) ?? false
        let kind: MediaItem.Kind = isImage ? .image : video != nil ? .video : .audio

        let duration = PremiereProject.ticks((video ?? audio)?.child("Duration")?.text).map(PremiereProject.time)
        var metadata = MediaMetadata(duration: isImage ? .zero : duration ?? .zero)
        if let video {
            metadata.naturalSize = Self.size(video.child("FrameRect")?.text) ?? .zero
            if !isImage, let rate = PremiereProject.ticks(video.child("FrameRate")?.text), rate > 0 {
                metadata.nominalFrameRate = Double(PremiereProject.ticksPerSecond) / Double(rate)
            }
        }
        if let audio, !isImage {
            let layout = audio.child("AudioChannelLayout")?.text ?? ""
            let channels = layout.components(separatedBy: "channellabel").count - 1
            metadata.audioChannelCount = channels > 0 ? channels : 2
            if let rate = PremiereProject.ticks(audio.child("FrameRate")?.text), rate > 0 {
                metadata.audioSampleRate = Double(PremiereProject.ticksPerSecond) / Double(rate)
            }
        }
        return media.item(key: object["ObjectUID"] ?? name, url: url, name: fileName ?? name, kind: kind, metadata: metadata)
    }

    /// Where a media file is: its absolute path where that's one this Mac
    /// can use and the file is there, otherwise its path relative to the
    /// project, which Premiere writes too for projects moved with their
    /// media. A Windows path is only of use relative.
    static func url(of media: MarkupElement, relativeTo base: URL?) -> URL? {
        let absolute = ["ActualMediaFilePath", "FilePath"].compactMap { media.child($0)?.text }.compactMap { path -> URL? in
            if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            if path.hasPrefix("file:") { return URL(string: path)?.standardizedFileURL }
            return nil
        }
        let relative = media.child("RelativePath").flatMap { element -> URL? in
            let path = element.text.replacingOccurrences(of: "\\", with: "/")
            guard !path.isEmpty, !path.hasPrefix("/"), path.firstIndex(of: ":") == nil, let base else { return nil }
            return base.appending(path: path, directoryHint: .notDirectory).standardizedFileURL
        }
        let candidates = absolute + [relative].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) } ?? candidates.first
    }

    /// A size from a rectangle written "left,top,right,bottom".
    private static func size(_ text: String?) -> CGSize? {
        let values = (text ?? "").split(separator: ",").compactMap { PremiereProject.number($0) }
        guard values.count == 4, values[2] > values[0], values[3] > values[1] else { return nil }
        return CGSize(width: values[2] - values[0], height: values[3] - values[1])
    }
}
