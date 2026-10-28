import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

/// Reads a Final Cut Pro FCPXML file's project into Montage's tracks.
///
/// Final Cut has no tracks. A project is a primary storyline (the spine) of
/// clips one after another, with other clips connected to them on numbered
/// lanes above and below, and storylines of their own connected the same
/// way. Clips can hold other clips: compound clips refer to a sequence of
/// their own, multicam clips to angles, synced clips and plain clips hold
/// theirs inside. Everything is flattened onto the timeline: each clip goes
/// where it plays, on its lane, and a clip holding others becomes the clips
/// inside it that play.
///
/// Every element has a local timeline: `offset` places it in its parent's,
/// `start` is where its own begins, and the elements inside or connected to
/// it are placed in that. Times are rationals, read into `CMTime` exactly.
struct FCPXMLImporter {
    private var resources: [String: MarkupElement] = [:]
    /// Titles' text style definitions by ID, which any title can use.
    private var textStyles: [String: MarkupElement] = [:]
    private let baseURL: URL?
    private var media = ImportedMedia()
    private var assembler = TimelineAssembler()
    private var report = ImportReport(format: .fcpxml)
    private var settings = ProjectSettings()
    /// Markers and chapter markers on the clips that show them, on the timeline.
    private var markers: [(time: CMTime, name: String)] = []

    static func read(_ root: MarkupElement, baseURL: URL?) throws -> ImportedProject {
        var importer = FCPXMLImporter(root: root, baseURL: baseURL)
        return try importer.run(root)
    }

    private init(root: MarkupElement, baseURL: URL?) {
        self.baseURL = baseURL
        for resource in root.child("resources")?.children ?? [] {
            if let id = resource["id"] { resources[id] = resource }
        }
        for definition in root.allDescendants where definition.name == "text-style-def" {
            if let id = definition["id"] { textStyles[id] = definition }
        }
    }

    private mutating func run(_ root: MarkupElement) throws -> ImportedProject {
        let projects = ([root] + root.allDescendants).filter { $0.name == "project" }
        guard let project = projects.first, let sequence = project.child("sequence"),
              let spine = sequence.child("spine") else { throw InterchangeError.noTimeline }
        if projects.count > 1 { report.add(.otherTimelines(count: projects.count - 1)) }

        if let format = sequence["format"].flatMap({ resources[$0] }) {
            if let width = format["width"].flatMap(Double.init), let height = format["height"].flatMap(Double.init),
               width > 0, height > 0 {
                settings.renderSize = CGSize(width: width, height: height)
            }
            if let frameDuration = InterchangeTime.parse(format["frameDuration"]), frameDuration > .zero {
                settings.frameDuration = frameDuration
            }
        }

        // The spine's first element starts at the sequence's timecode, which
        // is the start of the timeline.
        let origin = time(sequence["tcStart"]) ?? spine.children.lazy.compactMap { InterchangeTime.parse($0["offset"]) }.first ?? .zero
        importSequence(spine.children, in: Context(base: .zero, origin: origin))

        var montage = Project(settings: settings, media: media.items)
        (montage.tracks, montage.transitions) = assembler.timeline(report: &report)
        for marker in markers.sorted(by: { $0.time < $1.time }) {
            montage.addMarker(at: marker.time, name: marker.name)
        }
        return ImportedProject(project: montage, report: report, name: project["name"], mediaSources: media.sources,
                               mediaSourcePaths: media.writtenPaths)
    }

    // MARK: - Placement

    /// Where the elements being read go: how their parent's local time
    /// maps onto the timeline, the lane, and what the clips they're inside
    /// hand down.
    private struct Context {
        /// The timeline time of `origin`.
        var base: CMTime
        /// A time in the parent's local timeline.
        var origin: CMTime
        var lane = 0
        /// The stretch of the timeline a containing clip shows; anything
        /// inside it beyond that is trimmed off.
        var window: CMTimeRange?
        /// Only the picture or only the sound, for a clip that uses one.
        var component: Component?
        /// The settings and effects of the clips this one is inside.
        var inherited: [Inherited] = []
        /// The compound and multicam media being read, outermost first.
        var expanding: [String] = []

        /// Notes that a compound or multicam clip's media is being read.
        /// False if it already is, as for media that holds itself, or if
        /// it's nested deeper than any real project would be.
        mutating func enter(_ resource: String) -> Bool {
            guard !expanding.contains(resource), expanding.count < 64 else { return false }
            expanding.append(resource)
            return true
        }

        /// How fast the parent's local time runs against the timeline's: not
        /// normal inside a clip whose speed is changed.
        var speed = ClipSpeed.normal

        func timeline(_ local: CMTime) -> CMTime { base + speed.timelineDuration(ofMedia: local - origin) }

        /// A length of the parent's local time, on the timeline.
        func duration(_ local: CMTime) -> CMTime { speed.timelineDuration(ofMedia: local) }

        func within(_ range: CMTimeRange) -> CMTimeRange {
            window.map { $0.intersection(range) } ?? range
        }
    }

    /// A containing clip's settings, with the mapping of its own local time.
    private struct Inherited {
        var element: MarkupElement
        var base: CMTime
        var origin: CMTime
        var speed = ClipSpeed.normal

        /// A time in the element's local time, as a time from a clip's start.
        func clipTime(_ local: CMTime, clipStart: CMTime) -> CMTime {
            base + speed.timelineDuration(ofMedia: local - origin) - clipStart
        }
    }

    private enum Component {
        case video, audio

        init?(sourceEnable: String?) {
            switch sourceEnable {
            case "video": self = .video
            case "audio": self = .audio
            default: return nil
            }
        }

        /// What a clip shows, given its own choice and its container's: the
        /// container's, if it made one, as nothing else of the clip plays.
        static func combine(_ own: Component?, _ outer: Component?) -> Component? { outer ?? own }
    }

    /// The parts of an element that place it.
    private struct Timing {
        var offset: CMTime
        var start: CMTime
        var duration: CMTime
        var timelineStart: CMTime
        /// How long it lasts on the timeline, at the speed it plays.
        var timelineDuration: CMTime
        var lane: Int
        /// Where what it holds starts, in that's own time: `start`, mapped
        /// through its speed change if it has one.
        var contentStart: CMTime
        /// How fast what it holds plays against the timeline.
        var speed: ClipSpeed

        var timelineRange: CMTimeRange { CMTimeRange(start: timelineStart, duration: timelineDuration) }
        /// How much of what it holds plays.
        var contentDuration: CMTime { speed.mediaDuration(ofTimeline: timelineDuration) }
    }

    private static let storyElements: Set<String> = [
        "asset-clip", "clip", "ref-clip", "mc-clip", "sync-clip", "audition", "video", "audio",
        "title", "gap", "spine", "caption", "live-drawing",
    ]

    // MARK: - Sequences

    /// Elements one after another, as in a spine or an angle: each starts at
    /// its offset, or where the one before it ended if it has none. A
    /// transition is centred on the cut between the element before it and
    /// the one after, or, as some apps write it, overlaps both. A cross
    /// dissolve becomes one of Montage's, and any other is cut.
    private mutating func importSequence(_ elements: [MarkupElement], in context: Context) {
        var cursor = elements.lazy.compactMap { InterchangeTime.parse($0["offset"]) }.first ?? context.origin
        for element in elements {
            if element.name == "transition" {
                let duration = time(element["duration"]) ?? .zero
                let offset = time(element["offset"]) ?? cursor - duration
                let start = context.timeline(offset)
                let range = CMTimeRange(start: start, duration: context.duration(duration))
                let name = element["name"] ?? "Transition"
                if let kind = transitionKind(element) {
                    assembler.addTransition(range, lane: context.lane, as: kind, name: name)
                } else {
                    assembler.addTransition(range, lane: context.lane)
                    report.add(.transition(name: name), time: start)
                }
                cursor = offset
                continue
            }
            guard Self.storyElements.contains(element.name) else {
                if !["note", "metadata"].contains(element.name) { report.add(.setting(name: element.name)) }
                continue
            }
            if let end = importElement(element, in: context, offset: cursor) {
                cursor = end
            }
        }
    }

    /// A speed change that holds all through an element: a time map of two
    /// points, going forwards, as Final Cut writes a constant speed. Its
    /// speed, and the time in what the element holds at a time in its own.
    /// Nil for none, or for a ramp, a freeze or a reverse, which play at
    /// normal speed.
    private func speedChange(of element: MarkupElement) -> (speed: ClipSpeed, time: CMTime, value: CMTime)? {
        let points = element.child("timeMap")?.children("timept") ?? []
        guard points.count == 2, let start = time(points[0]["time"]), let value = time(points[0]["value"]),
              let end = time(points[1]["time"]), let endValue = time(points[1]["value"]),
              end > start, endValue > value else { return nil }
        // Final Cut writes the media's end to the nanosecond, so the speed
        // is taken to the nearest millionth.
        guard let speed = ClipSpeed(rate: (endValue - value).seconds / (end - start).seconds) else { return nil }
        return (speed, start, value)
    }

    /// Final Cut's Cross Dissolve, by its effect's ID, or by name as other
    /// apps write it.
    private static let crossDissolveUID = "FxPlug:4731E73A-8DAC-4113-9A30-AE85B1761265"

    /// What a transition becomes in Montage: a dissolve, if it's a cross
    /// dissolve, or nil to cut.
    private func transitionKind(_ transition: MarkupElement) -> ClipTransition.Kind? {
        let video = transition.child("filter-video")
        let effect = video?["ref"].flatMap { resources[$0] }
        if effect?["uid"] == Self.crossDissolveUID { return .crossDissolve }
        let names = [transition["name"], video?["name"], effect?["name"]].compactMap { $0?.lowercased() }
        return names.contains { $0 == "cross dissolve" || $0 == "dissolve" } ? .crossDissolve : nil
    }

    /// Reads one element and everything connected to it. Returns where it
    /// ends, in its parent's local time.
    @discardableResult
    private mutating func importElement(_ element: MarkupElement, in context: Context, offset fallback: CMTime) -> CMTime? {
        let offset = time(element["offset"]) ?? fallback
        let start = time(element["start"]) ?? .zero
        let duration = time(element["duration"]) ?? assetDuration(of: element, from: start) ?? .zero
        let name = element["name"]
        let retime = speedChange(of: element)
        var timing = Timing(
            offset: offset, start: start, duration: duration, timelineStart: context.timeline(offset),
            timelineDuration: context.duration(duration), lane: context.lane + Self.lane(element["lane"]),
            contentStart: start, speed: context.speed
        )
        if let retime {
            timing.contentStart = retime.value + retime.speed.mediaDuration(ofTimeline: start - retime.time)
            timing.speed = context.speed.combined(with: retime.speed)
        } else if element.children.contains(where: { $0.name == "timeMap" }) {
            report.add(.speedChange, clipName: name, time: timing.timelineStart)
        }
        // Connected to this element: its local time, from `start`.
        var connected = context
        connected.base = timing.timelineStart
        connected.origin = start
        connected.lane = timing.lane
        // Inside it: the time of what it holds, which its speed change maps
        // its local time to.
        var inside = connected
        inside.origin = timing.contentStart
        inside.speed = timing.speed
        let own = Inherited(element: element, base: timing.timelineStart, origin: start, speed: context.speed)

        // Markers on a part of the clip that's trimmed off, or hidden by
        // the clips it's inside, don't show in Final Cut either.
        let shown = context.within(timing.timelineRange)
        for marker in element.children where marker.name == "marker" || marker.name == "chapter-marker" {
            let time = inside.timeline(time(marker["start"]) ?? start)
            guard shown.duration > .zero, time >= shown.start, time < shown.end else { continue }
            markers.append((time, marker["value"] ?? ""))
        }
        let isEnabled = element["enabled"] != "0"
        if !isEnabled && element.name != "gap" && element.name != "spine" {
            report.add(.disabledClip, clipName: name, time: timing.timelineStart)
        }

        var merged: Set<Int> = []
        if isEnabled {
            inside.window = context.within(timing.timelineRange)
            switch element.name {
            case "asset-clip":
                inside.component = Component.combine(Component(sourceEnable: element["srcEnable"]), context.component)
                if let asset = element["ref"].flatMap({ resources[$0] }) {
                    importLeaf(element, asset: asset, timing: timing, context: context, component: inside.component)
                }
            case "video", "audio":
                merged = importComponent(element, timing: timing, context: context)
            case "clip", "sync-clip":
                inside.inherited.append(own)
                importContents(of: element, in: inside)
            case "ref-clip":
                inside.component = Component.combine(Component(sourceEnable: element["srcEnable"]), context.component)
                inside.inherited.append(own)
                if let ref = element["ref"], inside.enter(ref), let spine = resources[ref]?.child("sequence")?.child("spine") {
                    importSequence(spine.children, in: inside)
                }
            case "mc-clip":
                inside.component = Component.combine(Component(sourceEnable: element["srcEnable"]), context.component)
                inside.inherited.append(own)
                importMulticam(element, in: inside)
            case "audition":
                importAudition(element, in: context, offset: offset)
            case "spine":
                // A storyline of its own: its elements are placed from the first.
                var storyline = context
                storyline.base = timing.timelineStart
                storyline.origin = element.children.lazy.compactMap { InterchangeTime.parse($0["offset"]) }.first ?? .zero
                storyline.lane = timing.lane
                importSequence(element.children, in: storyline)
                return offset + sequenceDuration(element.children)
            case "title":
                importTitle(element, timing: timing, context: context)
            case "caption":
                report.add(.caption, clipName: name, time: timing.timelineStart)
            case "live-drawing":
                report.add(.generator(name: name ?? "Live Drawing"), clipName: name, time: timing.timelineStart)
            default:
                break
            }
        }

        // Connected elements play beside this one, whatever it shows.
        if element.name != "audition" && element.name != "spine" {
            for (index, child) in element.children.enumerated()
            where child["lane"] != nil && Self.storyElements.contains(child.name) && !merged.contains(index) {
                importElement(child, in: connected, offset: start)
            }
        }
        return offset + duration
    }

    /// The elements inside a clip or synced clip that aren't connected to
    /// it: its own storyline, in its local time.
    private mutating func importContents(of element: MarkupElement, in context: Context) {
        let primary = element.children.filter { $0["lane"] == nil && Self.storyElements.contains($0.name) }
        importSequence(primary, in: context)
    }

    /// A multicam clip shows one angle's picture and one angle's sound,
    /// which may be different angles.
    private mutating func importMulticam(_ element: MarkupElement, in context: Context) {
        var context = context
        guard let ref = element["ref"], context.enter(ref), let multicam = resources[ref]?.child("multicam") else { return }
        let angles = multicam.children("mc-angle")
        let sources = element.children("mc-source")
        func angle(for components: Set<String>) -> MarkupElement? {
            guard let id = sources.first(where: { components.contains($0["srcEnable"] ?? "all") })?["angleID"] else {
                return sources.isEmpty ? angles.first : nil
            }
            return angles.first { $0["angleID"] == id }
        }
        let video = angle(for: ["all", "video"])
        let audio = angle(for: ["all", "audio"])
        for (angle, component) in [(video, Component.video), (audio, Component.audio)] {
            guard let angle, context.component == nil || context.component == component else { continue }
            var inside = context
            // One angle for both: its clips keep their picture and sound together.
            inside.component = video?["angleID"] == audio?["angleID"] ? context.component : component
            if let source = sources.first(where: { $0["angleID"] == angle["angleID"] }) {
                inside.inherited.append(Inherited(element: source, base: context.base, origin: context.origin, speed: context.speed))
            }
            importSequence(angle.children, in: inside)
            if inside.component == context.component { break }
        }
    }

    /// An audition plays its first pick; the others are alternatives.
    private mutating func importAudition(_ element: MarkupElement, in context: Context, offset: CMTime) {
        let picks = element.children.filter { Self.storyElements.contains($0.name) }
        guard var pick = picks.first else { return }
        // The pick stands where the audition does.
        if pick["lane"] == nil, let lane = element["lane"] { pick.attributes.append(("lane", lane)) }
        importElement(pick, in: context, offset: offset)
        if picks.count > 1 {
            report.add(.auditionAlternatives(count: picks.count - 1), clipName: pick["name"], time: context.timeline(offset))
        }
    }

    /// A `video` or `audio` element: one part of an asset, or a generator.
    /// A video element with its own asset's audio connected to it in step,
    /// as Final Cut writes a plain clip, is one clip with both. Returns the
    /// indexes of the children merged into it.
    private mutating func importComponent(_ element: MarkupElement, timing: Timing, context: Context) -> Set<Int> {
        guard let resource = element["ref"].flatMap({ resources[$0] }) else { return [] }
        guard resource.name == "asset" else {
            report.add(.generator(name: element["name"] ?? resource["name"] ?? "Generator"),
                       clipName: element["name"], time: timing.timelineStart)
            return []
        }
        var component: Component? = element.name == "audio" ? .audio : .video
        var merged: Set<Int> = []
        if element.name == "video" {
            for (index, child) in element.children.enumerated()
            where child.name == "audio" && child["ref"] == element["ref"] && child["enabled"] != "0"
                && (time(child["offset"]) ?? timing.start) == timing.start
                && (time(child["start"]) ?? .zero) == timing.start && time(child["duration"]) == timing.duration
                && child.children.allSatisfy({ !Self.storyElements.contains($0.name) }) {
                merged.insert(index)
                component = nil
                break
            }
        }
        importLeaf(element, asset: resource, timing: timing, context: context,
                   component: Component.combine(component, context.component),
                   alsoApplying: merged.map { element.children[$0] })
        return merged
    }

    // MARK: - Clips

    /// A clip of an asset, on the lane its picture or sound goes on.
    private mutating func importLeaf(
        _ element: MarkupElement, asset: MarkupElement, timing: Timing, context: Context, component: Component?,
        alsoApplying extra: [MarkupElement] = []
    ) {
        let item = mediaItem(for: asset)
        let assetStart = time(asset["start"]) ?? .zero
        var clip: Clip
        if item.kind == .image {
            clip = Clip(content: item.content, sourceRange: CMTimeRange(start: .zero, duration: timing.timelineDuration),
                        timelineStart: timing.timelineStart)
        } else {
            clip = Clip(content: item.content, sourceRange: CMTimeRange(start: timing.contentStart - assetStart, duration: timing.contentDuration),
                        timelineStart: timing.timelineStart)
            clip.speed = timing.speed
        }
        let isAudio = item.kind == .audio || component == .audio
        if !isAudio && component == .video && item.metadata.hasAudio { clip.isAudioDetached = true }

        let name = element["name"] ?? asset["name"] ?? item.name
        applyAllSettings(of: element, alsoApplying: extra, to: &clip, item: item, isVideo: !isAudio, timing: timing,
                         context: context, clipName: name)
        add(clip, kind: isAudio ? .audio : .video, timing: timing, context: context, name: name)
    }

    /// A title as a text clip, with its words and their formatting. A title
    /// of a template other than the Basic Title keeps its words but not the
    /// rest of its look, which the report says.
    private mutating func importTitle(_ element: MarkupElement, timing: Timing, context: Context) {
        let effect = element["ref"].flatMap { resources[$0] }
        let reading = FCPXMLTitles.read(element, definitions: textStyles)
        let name = element["name"] ?? effect?["name"] ?? FCPXMLTitles.basicTitleName
        guard !reading.text.string.isEmpty else {
            report.add(.title, clipName: name, time: timing.timelineStart)
            return
        }
        var clip = Clip(content: .text(reading.text), sourceRange: CMTimeRange(start: .zero, duration: timing.timelineDuration),
                        timelineStart: timing.timelineStart)
        if FCPXMLTitles.isBasicTitle(effect) {
            for param in element.children("param") where !["Position", "Flatten", "Alignment"].contains(param["name"] ?? "") {
                report.add(.setting(name: param["name"] ?? "Title setting"), clipName: name, time: timing.timelineStart)
            }
        } else {
            report.add(.titleTemplate(name: effect?["name"] ?? name), clipName: name, time: timing.timelineStart)
        }
        for setting in reading.unsupported {
            report.add(.setting(name: setting), clipName: name, time: timing.timelineStart)
        }
        applyAllSettings(of: element, to: &clip, item: nil, isVideo: true, timing: timing, context: context, clipName: name)
        // The Basic Title's own position, in the frame's pixels from its
        // centre, upwards, moves the words within the title.
        if FCPXMLTitles.isBasicTitle(effect), let param = element.param("Position") {
            let own = Inherited(element: element, base: timing.timelineStart, origin: timing.start, speed: context.speed)
            let toClip: (CMTime) -> CMTime = { own.clipTime($0, clipStart: timing.timelineStart) }
            if let offset = animatable(param["value"], param, toClip, Self.pair) {
                movePosition(of: &clip, by: offset, clipName: name)
            }
        }
        add(clip, kind: .video, timing: timing, context: context, name: name)
    }

    /// Moves a clip's position by an offset in the frame's pixels, y up.
    private mutating func movePosition(of clip: inout Clip, by offset: Animatable<CGPoint>, clipName: String) {
        let size = settings.renderSize
        guard size.width > 0, size.height > 0 else { return }
        func moved(_ point: CGPoint, _ by: CGPoint) -> CGPoint {
            CGPoint(x: point.x + by.x / size.width, y: point.y - by.y / size.height)
        }
        let position = clip.transform.position
        if offset.isAnimated && position.isAnimated {
            report.add(.setting(name: "Position"), clipName: clipName, time: clip.timelineStart)
            return
        }
        if offset.isAnimated {
            clip.transform.position = Animatable(moved(position.value, offset.value), keyframes: offset.keyframes.map {
                Keyframe(time: $0.time, value: moved(position.value, $0.value), interpolation: $0.interpolation)
            })
        } else {
            clip.transform.position = Animatable(moved(position.value, offset.value), keyframes: position.keyframes.map {
                Keyframe(time: $0.time, value: moved($0.value, offset.value), interpolation: $0.interpolation)
            })
        }
    }

    /// Puts a clip's settings and effects onto it, after those of the clips
    /// it's inside.
    private mutating func applyAllSettings(
        of element: MarkupElement, alsoApplying extra: [MarkupElement] = [], to clip: inout Clip, item: MediaItem?,
        isVideo: Bool, timing: Timing, context: Context, clipName name: String
    ) {
        let own = Inherited(element: element, base: timing.timelineStart, origin: timing.start, speed: context.speed)
        let layers = context.inherited + [own] + extra.map {
            Inherited(element: $0, base: timing.timelineStart, origin: timing.start, speed: context.speed)
        }
        var applied: Set<String> = []
        var reportedNesting = false
        for (index, layer) in layers.enumerated() {
            let names = applySettings(of: layer, to: &clip, item: item, isVideo: isVideo, clipName: name)
            // A container's setting that the clip has as well: the clip's wins.
            if index >= context.inherited.count, !applied.isDisjoint(with: names), !reportedNesting {
                report.add(.nestedSettings, clipName: name, time: timing.timelineStart)
                reportedNesting = true
            }
            applied.formUnion(names)
        }
    }

    /// Puts a clip on the timeline, trimmed to what the clips it's inside
    /// show.
    private mutating func add(_ clip: Clip, kind: Track.Kind, timing: Timing, context: Context, name: String) {
        guard let window = context.window else {
            assembler.add(clip, kind: kind, lane: timing.lane, name: name)
            return
        }
        if let trimmed = clip.trimmed(to: window) {
            assembler.add(trimmed, kind: kind, lane: timing.lane, name: name)
        }
    }

    /// Puts one element's settings and effects onto a clip made inside it.
    /// Returns the names of the settings it had.
    private mutating func applySettings(
        of layer: Inherited, to clip: inout Clip, item: MediaItem?, isVideo: Bool, clipName: String
    ) -> Set<String> {
        let element = layer.element
        // An element's keyframes are timed in its own local time.
        let start = clip.timelineStart
        let toClip: (CMTime) -> CMTime = { layer.clipTime($0, clipStart: start) }
        var names: Set<String> = []

        for adjustment in element.children where adjustment.name.hasPrefix("adjust-") && adjustment["enabled"] != "0" {
            names.insert(adjustment.name)
            switch adjustment.name {
            case "adjust-volume":
                if let volume = animatable(adjustment["amount"], adjustment.param("amount"), toClip, Self.decibels) {
                    clip.volume = volume.mapped { Self.linearGain(decibels: $0) }
                }
            case "adjust-panner":
                if let amount = animatable(adjustment["amount"], adjustment.param("amount"), toClip, Self.number),
                   amount.isAnimated || amount.value != 0 {
                    var pan = Pan()
                    pan.position = amount.mapped { max(-1, min(1, $0 / 100)) }
                    clip.effects.append(Effect(.pan(pan)))
                }
                if let mode = adjustment["mode"], !mode.lowercased().contains("stereo") {
                    report.add(.setting(name: "Surround panning"), clipName: clipName, time: start)
                }
            case "adjust-blend" where isVideo:
                if let amount = animatable(adjustment["amount"], adjustment.param("amount"), toClip, Self.number) {
                    clip.opacity = amount.mapped { max(0, min(1, $0)) }
                }
                if let mode = adjustment["mode"], mode != "0", mode.lowercased() != "normal" {
                    report.add(.setting(name: "Blend mode"), clipName: clipName, time: start)
                }
            case "adjust-transform" where isVideo:
                applyTransform(adjustment, to: &clip, item: item, conform: element.child("adjust-conform"),
                               toClip: toClip, clipName: clipName)
            case "adjust-conform" where isVideo:
                // Applied with the transform; on its own, it scales.
                if element.child("adjust-transform") == nil {
                    clip.transform.scale = Animatable(conformScale(adjustment, item: item, clipName: clipName))
                }
            case "adjust-crop" where isVideo:
                let rects = adjustment.children.filter { $0.name.hasSuffix("-rect") }
                if rects.contains(where: { rect in rect.attributes.contains { Double($0.value) != 0 } }) {
                    report.add(.setting(name: "Crop"), clipName: clipName, time: start)
                }
            case "adjust-rollingShutter":
                if (adjustment["amount"] ?? "none") != "none" {
                    report.add(.setting(name: "Rolling shutter"), clipName: clipName, time: start)
                }
            case "adjust-colorConform":
                // How Final Cut tone maps HDR media into the project, which
                // Montage does by itself.
                break
            default:
                if isVideo || !Self.videoAdjustments.contains(adjustment.name) {
                    report.add(.setting(name: Self.settingName(adjustment.name)), clipName: clipName, time: start)
                }
            }
        }

        for source in element.children where source.name == "audio-channel-source" || source.name == "audio-role-source" {
            if source["enabled"] == "0" || source["active"] == "0" || !source.children.isEmpty {
                report.add(.setting(name: "Audio channel settings"), clipName: clipName, time: start)
                break
            }
        }

        for filter in element.children
        where filter.name == "filter-video" || filter.name == "filter-audio" || filter.name == "filter-video-mask" {
            let isVideoFilter = filter.name != "filter-audio"
            guard isVideoFilter == isVideo || (!isVideoFilter && item?.metadata.hasAudio == true) else { continue }
            names.insert(filter.name)
            if let effect = effect(for: filter, toClip: toClip, clipName: clipName, at: start) {
                clip.effects.append(effect)
            }
        }
        return names
    }

    private static let videoAdjustments: Set<String> = [
        "adjust-crop", "adjust-corners", "adjust-conform", "adjust-transform", "adjust-blend", "adjust-stabilization",
        "adjust-rollingShutter", "adjust-360-transform", "adjust-reorient", "adjust-orientation", "adjust-cinematic",
        "adjust-colorConform",
    ]

    /// "adjust-noiseReduction" as "Noise reduction".
    private static func settingName(_ adjustment: String) -> String {
        let name = adjustment.replacingOccurrences(of: "adjust-", with: "")
        var words = ""
        for character in name {
            if character.isUppercase, !words.isEmpty { words += " " }
            words.append(character)
        }
        return words.prefix(1).uppercased() + words.dropFirst().lowercased()
    }

    /// Final Cut's position is measured from the frame's centre, upwards, in
    /// hundredths of the frame's height; its rotation turns anticlockwise.
    private mutating func applyTransform(
        _ adjustment: MarkupElement, to clip: inout Clip, item: MediaItem?, conform: MarkupElement?,
        toClip: (CMTime) -> CMTime, clipName: String
    ) {
        let size = settings.renderSize
        let aspect = size.height > 0 ? size.width / size.height : 16 / 9
        if let position = animatable(adjustment["position"], adjustment.param("position"), toClip, Self.pair) {
            let mapped = Animatable(Self.position(position.value, aspect: aspect), keyframes: position.keyframes.map {
                Keyframe(time: $0.time, value: Self.position($0.value, aspect: aspect), interpolation: $0.interpolation)
            })
            clip.transform.position = mapped
        }
        let conformScale = conformScale(conform, item: item, clipName: clipName)
        if let scale = animatable(adjustment["scale"], adjustment.param("scale"), toClip, Self.pair) {
            if ([scale.value] + scale.keyframes.map(\.value)).contains(where: { abs($0.x - $0.y) > 0.0001 }) {
                report.add(.uneven(name: "Scale"), clipName: clipName, time: clip.timelineStart)
            }
            let mapped = Animatable(Double(scale.value.x) * conformScale, keyframes: scale.keyframes.map {
                Keyframe(time: $0.time, value: Double($0.value.x) * conformScale, interpolation: $0.interpolation)
            })
            clip.transform.scale = mapped
        } else if conformScale != 1 {
            clip.transform.scale = Animatable(conformScale)
        }
        if let rotation = animatable(adjustment["rotation"], adjustment.param("rotation"), toClip, Self.number) {
            clip.transform.rotation = rotation.mapped { $0 == 0 ? 0 : -$0 }
        }
        if let anchor = adjustment["anchor"].flatMap(Self.pair), anchor != .zero {
            report.add(.setting(name: "Anchor point"), clipName: clipName, time: clip.timelineStart)
        }
    }

    private static func position(_ point: CGPoint, aspect: Double) -> CGPoint {
        CGPoint(x: 0.5 + point.x / 100 / aspect, y: 0.5 - point.y / 100)
    }

    /// The scale that gives Final Cut's spatial conform in Montage, whose
    /// pictures always start fitted to the frame: filling it, or at the
    /// media's own size.
    private mutating func conformScale(_ conform: MarkupElement?, item: MediaItem?, clipName: String) -> Double {
        let type = conform?["type"] ?? "fit"
        guard type != "fit" else { return 1 }
        let media = item?.metadata.presentationSize ?? .zero
        let frame = settings.renderSize
        guard media.width > 0, media.height > 0 else {
            report.add(.setting(name: "Spatial conform"), clipName: clipName)
            return 1
        }
        let across = frame.width / media.width, down = frame.height / media.height
        let fit = min(across, down)
        return type == "fill" ? max(across, down) / fit : 1 / fit
    }

    // MARK: - Effects

    /// A filter as one of Montage's effects where it maps onto one, or
    /// kept turned off as an unsupported effect.
    private mutating func effect(
        for filter: MarkupElement, toClip: @escaping (CMTime) -> CMTime, clipName: String, at time: CMTime
    ) -> Effect? {
        let isVideo = filter.name != "filter-audio"
        // A masked effect is kept whole, mask and all.
        let inner = filter.name == "filter-video-mask" ? filter.child("filter-video") : filter
        guard let inner else { return nil }
        let resource = inner["ref"].flatMap { resources[$0] }
        let uid = resource?["uid"] ?? ""
        let name = inner["name"] ?? resource?["name"] ?? uid
        let isEnabled = filter["enabled"] != "0" && inner["enabled"] != "0"
        let parameters = Self.flattenedParameters(inner)

        if uid.hasPrefix(EffectMapping.montageUIDPrefix), let data = inner.child("data")?.text,
           let kind = EffectMapping.montageEffect(fromData: data) {
            return Effect(isEnabled: isEnabled, kind)
        }
        if filter.name != "filter-video-mask" {
            let lookup = ImportedParameters { [self] wanted in
                guard let param = parameters.first(where: { $0.name.lowercased() == wanted.lowercased() })?.element else {
                    return nil
                }
                return animatable(param["value"], param, toClip, Self.number)
            }
            if let kind = EffectMapping.fcpxml(uid: uid, name: name, parameters: lookup, frameWidth: settings.renderSize.width) {
                return Effect(isEnabled: isEnabled, kind)
            }
        }
        report.add(.unsupportedEffect(name: name), clipName: clipName, time: time)
        return Effect(isEnabled: false, .unsupported(UnsupportedEffect(
            format: InterchangeFormat.fcpxml.rawValue, identifier: uid, name: name, isVideo: isVideo,
            parameters: parameters.map {
                .init(name: $0.name, key: $0.element["key"], value: $0.element["value"],
                      isAnimated: $0.element.child("keyframeAnimation") != nil)
            },
            original: filter.xmlString()
        )))
    }

    /// An effect's parameters, those inside others named by their path.
    private static func flattenedParameters(_ element: MarkupElement, prefix: String = "") -> [(name: String, element: MarkupElement)] {
        element.children("param").flatMap { param -> [(name: String, element: MarkupElement)] in
            let name = prefix + (param["name"] ?? "")
            return [(name, param)] + flattenedParameters(param, prefix: name + "/")
        }
    }

    // MARK: - Values

    /// A setting as a Montage parameter: its value, and its keyframes timed
    /// from the clip's start. Nil if it has neither.
    private func animatable<Value>(
        _ value: String?, _ param: MarkupElement?, _ toClip: (CMTime) -> CMTime, _ parse: (String) -> Value?
    ) -> Animatable<Value>? {
        let keyframes = param?.child("keyframeAnimation")?.children("keyframe").compactMap { keyframe -> Keyframe<Value>? in
            guard let time = time(keyframe["time"]), let value = keyframe["value"].flatMap(parse) else { return nil }
            return Keyframe(time: toClip(time), value: value, interpolation: Self.interpolation(keyframe["interp"]))
        } ?? []
        guard let initial = (value ?? param?["value"]).flatMap(parse) ?? keyframes.first?.value else { return nil }
        return Animatable(initial, keyframes: keyframes)
    }

    private static func interpolation(_ interp: String?) -> Interpolation {
        switch interp {
        case "ease": .easeInOut
        case "easeIn": .easeIn
        case "easeOut": .easeOut
        default: .linear
        }
    }

    private static func number(_ string: String) -> Double? {
        string.split(separator: " ").first.flatMap { Double($0) }
    }

    private static func pair(_ string: String) -> CGPoint? {
        let parts = string.split(separator: " ").compactMap { Double($0) }
        guard let x = parts.first else { return nil }
        return CGPoint(x: x, y: parts.count > 1 ? parts[1] : x)
    }

    /// "-6dB" as -6. Silence may be written as "-inf".
    private static func decibels(_ string: String) -> Double? {
        let trimmed = string.lowercased().replacingOccurrences(of: "db", with: "").trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("-inf") { return -.infinity }
        return Double(trimmed)
    }

    /// Final Cut's lowest level, -96dB, is silence.
    static func linearGain(decibels: Double) -> Double {
        decibels <= -96 ? 0 : pow(10, decibels / 20)
    }

    /// A lane number, held to what a project could really have, so lanes
    /// added up through nested storylines can't overflow.
    private static func lane(_ string: String?) -> Int {
        string.flatMap { Int($0) }.map { max(-1000, min(1000, $0)) } ?? 0
    }

    private func time(_ string: String?) -> CMTime? {
        InterchangeTime.parse(string)
    }

    // MARK: - Media

    /// How long an asset clip with no duration of its own lasts: the rest of
    /// its asset.
    private func assetDuration(of element: MarkupElement, from start: CMTime) -> CMTime? {
        guard element.name == "asset-clip", let asset = element["ref"].flatMap({ resources[$0] }),
              let duration = time(asset["duration"]) else { return nil }
        return duration - (start - (time(asset["start"]) ?? .zero))
    }

    private func sequenceDuration(_ elements: [MarkupElement]) -> CMTime {
        var end = CMTime.zero, first: CMTime?
        for element in elements where Self.storyElements.contains(element.name) {
            guard let offset = time(element["offset"]), let duration = time(element["duration"]) else { continue }
            first = first ?? offset
            end = max(end, offset + duration)
        }
        return end - (first ?? .zero)
    }

    /// The media item for an asset, made the first time the asset's file
    /// is used.
    private mutating func mediaItem(for asset: MarkupElement) -> MediaItem {
        let representations = asset.children("media-rep")
        let source = (representations.first { ($0["kind"] ?? "original-media") == "original-media" } ?? representations.first)?["src"]
            ?? asset["src"]
        let reference = ImportedMedia.reference(from: source, relativeTo: baseURL)
        let url = reference?.url
        let format = asset["format"].flatMap { resources[$0] }
        let duration = time(asset["duration"]) ?? .zero
        let fileType = url.flatMap { UTType(filenameExtension: $0.pathExtension) }

        let hasVideo = asset["hasVideo"].map { $0 == "1" } ?? !(fileType?.conforms(to: .audio) ?? false)
        let hasAudio = asset["hasAudio"].map { $0 == "1" } ?? (fileType?.conforms(to: .audiovisualContent) ?? false)
        let isImage = hasVideo && (fileType?.conforms(to: .image) ?? false
            || duration == .zero || (format != nil && format?["frameDuration"] == nil))
        let kind: MediaItem.Kind = isImage ? .image : hasVideo ? .video : .audio

        var metadata = MediaMetadata(duration: isImage ? .zero : duration)
        if hasVideo, let format {
            metadata.naturalSize = CGSize(width: format["width"].flatMap(Double.init) ?? 0,
                                          height: format["height"].flatMap(Double.init) ?? 0)
            if let frameDuration = time(format["frameDuration"]), frameDuration > .zero {
                metadata.nominalFrameRate = 1 / frameDuration.seconds
            }
        }
        if hasAudio && !isImage {
            metadata.audioChannelCount = asset["audioChannels"].flatMap(Int.init) ?? 2
            metadata.audioSampleRate = Self.sampleRate(asset["audioRate"]) ?? 48000
        }
        let name = asset["name"] ?? url?.lastPathComponent ?? "Media"
        return media.item(key: asset["id"] ?? name, reference: reference, name: name, kind: kind, metadata: metadata)
    }

    /// "48000", or "48k" as sequences write it.
    static func sampleRate(_ string: String?) -> Double? {
        guard let string else { return nil }
        if string.hasSuffix("k") { return Double(string.dropLast()).map { $0 * 1000 } }
        return Double(string)
    }
}

extension MarkupElement {
    /// A setting's `param` by name, where its keyframes are.
    func param(_ name: String) -> MarkupElement? {
        children("param").first { $0["name"] == name }
    }
}
