import CoreGraphics
import CoreMedia
import Foundation
import MontageEngine
import UniformTypeIdentifiers

/// Reads the timeline from an AAF file, as Avid Media Composer, Premiere Pro
/// and DaVinci Resolve export it.
///
/// An AAF file holds mobs: a composition mob for each timeline, master mobs
/// for the clips in the bin, and source mobs for the files (and tapes)
/// they came from. The timeline is a composition mob's timeline slots, one
/// for each track, each holding a sequence of components counted in the
/// slot's edit rate: source clips, which refer to a stretch of another
/// mob's slot, fillers, which are gaps, transitions, which overlap the
/// components either side of them, and operation groups, which are effects
/// applied to the segments inside them. A source clip is followed through
/// its master mob down to the source mob of the file, whose descriptor has
/// the file's URL in a network locator.
///
/// The timeline is the composition mob marked top-level, or failing that,
/// one no other composition uses. Markers come from its event slots.
struct AAFImporter {
    private let file: AAFFile
    private let baseURL: URL?
    private var mobs: [MobID: AAFObject] = [:]
    private var definitionNames: [AUID: String] = [:]
    private var timeWarps: Set<AUID> = []
    private var media = ImportedMedia()
    private var report = ImportReport(format: .aaf)
    private var settings = ProjectSettings()
    private var markers: [Marker] = []
    private var clips: [PendingClip] = []
    private var transitions: [(range: CMTimeRange, lane: Int)] = []
    /// The media each source mob became, by its ID.
    private var mediaItems: [MobID: MediaItem] = [:]
    private var hasRenderSize = false
    /// The master mob being imported, when there's no composition: its
    /// name is the name of the media it plays.
    private var currentMasterName: String?

    /// Past this, nesting is taken to loop.
    private static let maximumDepth = 32
    /// Lanes between one slot's and the next, leaving room for the layers
    /// of a nested scope or a collapsed track inside a slot.
    private static let laneSpacing = 100

    /// A clip found on the timeline, before picture and sound in step are
    /// made one clip.
    private struct PendingClip {
        var clip: Clip
        var kind: Track.Kind
        var lane: Int
        var name: String
    }

    /// Where a slot's positions fall on the timeline.
    private struct Context {
        var kind: Track.Kind
        var lane: Int
        /// The edit rate of the slot being read, its positions' units.
        var rate: AAFRational
        /// The timeline time of `origin`, a time in the slot.
        var base: CMTime
        var origin: CMTime
        /// The part of the timeline the slot shows, when it's nested.
        var window: CMTimeRange?
        /// Composition mobs being read, to stop at one that uses itself.
        var compositions: Set<MobID>
        /// For a source clip inside a speed change: its length on the
        /// timeline, played at normal speed.
        var lengthOverride: Int64?

        func timeline(_ position: Int64) -> CMTime? {
            AAFImporter.time(position, rate).map { base + ($0 - origin) }
        }
    }

    static func read(_ data: Data, baseURL: URL?) throws -> ImportedProject {
        let file: AAFFile
        do {
            file = try AAFFile(data)
        } catch .notCompoundFile {
            throw InterchangeError.unsupportedFormat
        } catch {
            throw InterchangeError.unreadable(nil)
        }
        var importer = AAFImporter(file: file, baseURL: baseURL)
        return try importer.run()
    }

    private init(file: AAFFile, baseURL: URL?) {
        self.file = file
        self.baseURL = baseURL
    }

    private mutating func run() throws -> ImportedProject {
        // A compound file without an AAF header is some other kind of document.
        guard let header = file.root.strongReference(AAFProperty.ID.header),
              header.isKind(of: AUID("0d010101-0101-2f00-060e-2b3402060101")) || header.has(AAFProperty.ID.content) else {
            throw InterchangeError.unsupportedFormat
        }
        if let dictionary = header.strongReference(AAFProperty.ID.dictionary) {
            readDefinitions(dictionary)
        }
        let allMobs = header.strongReference(AAFProperty.ID.content)?.strongReferences(AAFProperty.ID.mobs) ?? []
        for mob in allMobs {
            if let id = mob.mobID(AAFProperty.ID.mobID), mobs[id] == nil { mobs[id] = mob }
        }

        let timelines = topLevelCompositions(allMobs)
        let composition: AAFObject
        if let first = timelines.first {
            composition = first
            if timelines.count > 1 { report.add(.otherTimelines(count: timelines.count - 1)) }
            importComposition(composition)
            countFromTheHour(of: composition)
        } else {
            // Clips exported from a bin, with no sequence: one after another.
            let masters = allMobs.filter { $0.isKind(of: AAFClass.masterMob) }
            guard let first = masters.first else { throw InterchangeError.noTimeline }
            composition = first
            var start = CMTime.zero
            for master in masters {
                start = importComposition(master, at: start)
            }
        }

        var project = Project(settings: settings, media: media.items)
        project.tracks = assembleTracks()
        project.markers = markers.sorted { $0.time < $1.time }
        return ImportedProject(
            project: project, report: report, name: composition.string(AAFProperty.ID.mobName), mediaSources: media.sources
        )
    }

    /// Counts the timeline from the hour its first clip starts in, when
    /// that's within ten minutes after the hour, as the EDL importer does.
    /// Premiere Pro and Pro Tools count their timelines from 00:00:00:00
    /// and put an hour of filler before a session starting at 01:00:00:00;
    /// Media Composer and Resolve start theirs at their first frame, which
    /// is within the first hour, so they stay as they are.
    ///
    /// Hours are counted in timecode, at the composition's timecode rate,
    /// so an hour of drop-frame 29.97 is 107,892 frames.
    private mutating func countFromTheHour(of composition: AAFObject) {
        guard let first = clips.map(\.clip.timelineStart).min(), first.isNumeric, first > .zero,
              let hour = Self.timecodeHour(before: first, in: composition) else { return }
        for index in clips.indices { clips[index].clip.timelineStart = clips[index].clip.timelineStart - hour }
        transitions = transitions.map { (CMTimeRange(start: $0.range.start - hour, duration: $0.range.duration), $0.lane) }
        markers = markers.map { marker in
            var marker = marker
            marker.time = max(.zero, marker.time - hour)
            return marker
        }
    }

    /// The start of the timecode hour a time is in, if the time is in its
    /// first ten minutes and isn't in the first hour.
    private static func timecodeHour(before start: CMTime, in composition: AAFObject) -> CMTime? {
        // The composition's timecode: its rate, frames a second and whether
        // it drops frames. Without one, the first picture or sound slot's rate.
        var rate: AAFRational?
        var fps: Int64?
        var drop = false
        for slot in composition.strongReferences(AAFProperty.ID.slots) {
            guard let slotRate = validRate(slot.rational(AAFProperty.ID.editRate)),
                  let segment = slot.strongReference(AAFProperty.ID.segment) else { continue }
            let timecode = segment.isKind(of: AAFClass.timecode) ? segment
                : segment.strongReferences(AAFProperty.ID.components).first { $0.isKind(of: AAFClass.timecode) }
            if let timecode {
                rate = slotRate
                fps = timecode.integer(AAFProperty.ID.timecodeFPS)
                drop = timecode.bool(AAFProperty.ID.timecodeDrop) ?? false
                break
            }
            if rate == nil { rate = slotRate }
        }
        guard let rate else { return nil }
        let base = fps.flatMap { $0 > 0 && $0 <= 1000 ? $0 : nil }
            ?? Int64((Double(rate.numerator) / Double(rate.denominator)).rounded())
        guard base > 0 else { return nil }
        let count = (start.seconds * Double(rate.numerator) / Double(rate.denominator)).rounded()
        // Past any real timeline, there's no hour to count from.
        guard count.isFinite, count >= 0, count < 1e15 else { return nil }
        let frames = Int64(count)
        // An hour of timecode, without and with dropped frames; files don't
        // always say which an NTSC timeline's is, so both are tried.
        let isNTSC = rate.denominator == 1001
        let dropped = base % 30 == 0 ? base * 3600 - base / 15 * 54 : nil
        let hours = (drop ? [dropped, base * 3600] : [base * 3600, isNTSC ? dropped : nil]).compactMap { $0 }
        for hourFrames in hours where hourFrames > 0 {
            let count = frames / hourFrames
            guard count >= 1, frames - count * hourFrames <= base * 600 else { continue }
            return Self.time(count * hourFrames, rate)
        }
        return nil
    }

    // MARK: - Definitions and mobs

    private mutating func readDefinitions(_ dictionary: AAFObject) {
        for pid in [AAFProperty.ID.operationDefinitions, AAFProperty.ID.parameterDefinitions, AAFProperty.ID.dataDefinitions] {
            for definition in dictionary.strongReferences(pid) {
                guard let id = definition.auid(AAFProperty.ID.identification) else { continue }
                if let name = definition.string(AAFProperty.ID.name), !name.isEmpty { definitionNames[id] = name }
                if definition.bool(AAFProperty.ID.isTimeWarp) == true { timeWarps.insert(id) }
            }
        }
    }

    /// The timelines to import from: composition mobs marked top-level, or
    /// failing that, those no other composition mob uses.
    private func topLevelCompositions(_ allMobs: [AAFObject]) -> [AAFObject] {
        let compositions = allMobs.filter { $0.isKind(of: AAFClass.compositionMob) }
        let marked = compositions.filter { $0.auid(AAFProperty.ID.usageCode) == AAFDefinition.topLevelUsage }
        if !marked.isEmpty { return marked }
        var used: Set<MobID> = []
        for composition in compositions {
            for slot in composition.strongReferences(AAFProperty.ID.slots) {
                if let segment = slot.strongReference(AAFProperty.ID.segment) {
                    collectReferences(segment, into: &used, depth: 0)
                }
            }
        }
        let unused = compositions.filter { composition in
            composition.mobID(AAFProperty.ID.mobID).map { !used.contains($0) } ?? true
        }
        return unused.isEmpty ? compositions : unused
    }

    private func collectReferences(_ segment: AAFObject, into used: inout Set<MobID>, depth: Int) {
        guard depth < Self.maximumDepth else { return }
        if let id = segment.mobID(AAFProperty.ID.sourceID), !id.isZero { used.insert(id) }
        let children = [AAFProperty.ID.components, AAFProperty.ID.inputSegments, AAFProperty.ID.alternates,
                        AAFProperty.ID.choices, AAFProperty.ID.scopeSlots].flatMap { segment.strongReferences($0) }
            + [AAFProperty.ID.selected, AAFProperty.ID.transitionOperationGroup].compactMap { segment.strongReference($0) }
        for child in children {
            collectReferences(child.strongReference(AAFProperty.ID.segment) ?? child, into: &used, depth: depth + 1)
        }
    }

    // MARK: - Timeline

    /// A mob's timeline slots, from `start` on the timeline; returns where
    /// the longest of them ends.
    @discardableResult
    private mutating func importComposition(_ composition: AAFObject, at start: CMTime = .zero) -> CMTime {
        var videoLanes = 0
        var audioLanes = 0
        var end = start
        var compositions: Set<MobID> = []
        if let id = composition.mobID(AAFProperty.ID.mobID) { compositions.insert(id) }
        currentMasterName = composition.isKind(of: AAFClass.masterMob) ? composition.string(AAFProperty.ID.mobName) : nil
        defer { currentMasterName = nil }

        for slot in composition.strongReferences(AAFProperty.ID.slots) {
            guard let segment = slot.strongReference(AAFProperty.ID.segment) else { continue }
            if slot.isKind(of: AAFClass.eventMobSlot) || slot.has(AAFProperty.ID.eventEditRate) {
                if let rate = Self.validRate(slot.rational(AAFProperty.ID.eventEditRate)) {
                    let context = Context(kind: .video, lane: 0, rate: rate, base: start, origin: .zero, window: nil,
                                          compositions: compositions)
                    importMarkers(segment, context: context, depth: 0)
                }
                continue
            }
            guard let rate = Self.validRate(slot.rational(AAFProperty.ID.editRate)) else { continue }
            let kind: Track.Kind
            let lane: Int
            switch dataKind(of: segment) {
            case .video?:
                kind = .video
                lane = videoLanes * Self.laneSpacing
                if videoLanes == 0, start == .zero {
                    settings.frameDuration = InterchangeTime.time(Int64(rate.denominator), over: Int64(rate.numerator))
                }
                videoLanes += 1
            case .audio?:
                kind = .audio
                lane = -audioLanes * Self.laneSpacing
                audioLanes += 1
            default:
                // Timecode, edge code and the like.
                continue
            }
            let context = Context(kind: kind, lane: lane, rate: rate, base: start, origin: .zero, window: nil,
                                  compositions: compositions)
            importSegment(segment, at: 0, context: context, depth: 0)
            if let length = Self.time(Self.length(of: segment), rate) { end = max(end, start + length) }
        }
        return end
    }

    /// Whether a component carries picture or sound, by its data definition.
    private func dataKind(of component: AAFObject) -> Track.Kind? {
        guard let id = component.weakReferenceKey(AAFProperty.ID.dataDefinition).flatMap({ AUID(bytes: $0) }) else {
            return nil
        }
        switch id {
        case AAFDefinition.picture, AAFDefinition.legacyPicture, AAFDefinition.pictureWithMatte: return .video
        case AAFDefinition.sound, AAFDefinition.legacySound: return .audio
        default:
            let name = definitionNames[id]?.lowercased() ?? ""
            if name.contains("picture") { return .video }
            if name.contains("sound") { return .audio }
            return nil
        }
    }

    /// A segment that starts at `position` in its slot.
    private mutating func importSegment(_ segment: AAFObject, at position: Int64, context: Context, depth: Int) {
        guard depth < Self.maximumDepth else { return }
        let length = Self.length(of: segment)

        if segment.isKind(of: AAFClass.sequence) {
            var context = context
            context.lengthOverride = nil
            var position = position
            for component in segment.strongReferences(AAFProperty.ID.components) {
                let componentLength = Self.length(of: component)
                if component.isKind(of: AAFClass.transition) {
                    // A transition overlaps the end of the component before
                    // it and the start of the one after.
                    let (start, overflow) = position.subtractingReportingOverflow(componentLength)
                    guard !overflow else { return }
                    if componentLength > 0, let from = context.timeline(start), let to = context.timeline(position) {
                        transitions.append((CMTimeRange(start: from, end: to), context.lane))
                        let operation = component.strongReference(AAFProperty.ID.transitionOperationGroup)
                        report.add(.transition(name: operation.map(operationName) ?? "Video Dissolve"), time: from)
                    }
                    position = start
                    continue
                }
                importSegment(component, at: position, context: context, depth: depth + 1)
                let (sum, overflow) = position.addingReportingOverflow(componentLength)
                guard !overflow else { return }
                position = sum
            }
        } else if segment.isKind(of: AAFClass.sourceClip) {
            importSourceClip(segment, at: position, length: context.lengthOverride ?? length, context: context, depth: depth)
        } else if segment.isKind(of: AAFClass.operationGroup) {
            importOperationGroup(segment, at: position, length: length, context: context, depth: depth)
        } else if segment.isKind(of: AAFClass.selector) {
            let alternates = segment.strongReferences(AAFProperty.ID.alternates)
            let selected = segment.strongReference(AAFProperty.ID.selected)
            if let selected, isEmpty(selected, depth: depth) {
                // Avid mutes a clip by selecting what's under it instead.
                for alternate in alternates where !isEmpty(alternate, depth: depth) {
                    report.add(.disabledClip, clipName: clipName(firstSourceClip(in: alternate, depth: depth)),
                               time: context.timeline(position))
                }
                return
            }
            if !alternates.isEmpty {
                report.add(.auditionAlternatives(count: alternates.count), time: context.timeline(position))
            }
            if let selected {
                importSegment(selected, at: position, context: context, depth: depth + 1)
            }
        } else if segment.isKind(of: AAFClass.essenceGroup) {
            if let choice = segment.strongReferences(AAFProperty.ID.choices).first {
                importSegment(choice, at: position, context: context, depth: depth + 1)
            }
        } else if segment.isKind(of: AAFClass.nestedScope) {
            // Layers, each over those before it, which it refers to by
            // scope references to show what's under it.
            importLayers(segment.strongReferences(AAFProperty.ID.scopeSlots), at: position, context: context, depth: depth)
        } else if segment.isKind(of: AAFClass.event) {
            importMarkers(segment, context: context, depth: depth)
        }
        // Fillers are gaps, and scope references show the layers under
        // them, which are already on the tracks below; timecode and the
        // like have nothing to show.
    }

    /// Segments stacked as layers, the first lowest, each on a lane of its own.
    private mutating func importLayers(_ layers: [AAFObject], at position: Int64, context: Context, depth: Int) {
        for (index, layer) in layers.enumerated() {
            var layered = context
            layered.lane = context.kind == .video ? context.lane + index : context.lane - index
            importSegment(layer, at: position, context: layered, depth: depth + 1)
        }
    }

    /// Whether a segment shows nothing of its own: only gaps, or the layers
    /// under it.
    private func isEmpty(_ segment: AAFObject, depth: Int) -> Bool {
        guard depth < Self.maximumDepth else { return true }
        if segment.isKind(of: AAFClass.scopeReference) || segment.isKind(of: AAFClass.filler) { return true }
        if segment.isKind(of: AAFClass.sequence) {
            return segment.strongReferences(AAFProperty.ID.components).allSatisfy {
                $0.isKind(of: AAFClass.transition) || isEmpty($0, depth: depth + 1)
            }
        }
        return false
    }

    /// The first source clip in a segment, to name it by.
    private func firstSourceClip(in segment: AAFObject, depth: Int) -> AAFObject? {
        guard depth < Self.maximumDepth else { return nil }
        if segment.isKind(of: AAFClass.sourceClip) { return segment }
        let children = [AAFProperty.ID.components, AAFProperty.ID.inputSegments, AAFProperty.ID.choices,
                        AAFProperty.ID.scopeSlots].flatMap { segment.strongReferences($0) }
            + [AAFProperty.ID.selected].compactMap { segment.strongReference($0) }
        for child in children {
            if let clip = firstSourceClip(in: child, depth: depth + 1) { return clip }
        }
        return nil
    }

    // MARK: - Source clips

    private mutating func importSourceClip(_ clip: AAFObject, at position: Int64, length: Int64, context: Context, depth: Int) {
        guard length > 0, let sourceID = clip.mobID(AAFProperty.ID.sourceID), !sourceID.isZero,
              let start = context.timeline(position), let duration = Self.time(length, context.rate) else { return }
        let slotID = clip.integer(AAFProperty.ID.sourceMobSlotID) ?? 0
        let startTime = clip.int64(AAFProperty.ID.startTime) ?? 0
        let range = CMTimeRange(start: start, duration: duration)
        let window = context.window.map { $0.intersection(range) } ?? range
        guard window.duration > .zero else { return }

        guard let mob = mobs[sourceID] else {
            report.add(.missingMedia(file: sourceID.hex), time: start)
            return
        }
        guard let offset = Self.time(startTime, context.rate) else { return }

        // Another timeline, nested: its clips, played from the clip's start.
        if mob.isKind(of: AAFClass.compositionMob) {
            guard !context.compositions.contains(sourceID),
                  let slot = Self.slot(slotID, of: mob, kind: context.kind, importer: self),
                  let segment = slot.strongReference(AAFProperty.ID.segment),
                  let rate = Self.validRate(slot.rational(AAFProperty.ID.editRate)) else { return }
            let origin = Self.time(slot.int64(AAFProperty.ID.origin) ?? 0, rate) ?? .zero
            var nested = context
            nested.rate = rate
            nested.base = start
            nested.origin = origin + offset
            nested.window = window
            nested.compositions.insert(sourceID)
            nested.lengthOverride = nil
            importSegment(segment, at: 0, context: nested, depth: depth + 1)
            return
        }

        guard let source = resolve(mob, slotID: slotID, offset: offset) else { return }
        let name = mob.string(AAFProperty.ID.mobName).flatMap { $0.isEmpty ? nil : $0 } ?? source.item.name
        var imported = Clip(
            content: source.item.content,
            sourceRange: CMTimeRange(start: source.item.kind == .image ? .zero : source.start, duration: duration),
            timelineStart: start
        )
        if context.kind == .audio {
            applyFades(of: clip, to: &imported, rate: context.rate)
        }
        guard let trimmed = imported.trimmed(to: window) else { return }
        clips.append(PendingClip(
            clip: trimmed, kind: source.item.kind == .audio ? .audio : context.kind, lane: context.lane, name: name
        ))
    }

    /// A sound clip's fades, as volume keyframes.
    private func applyFades(of source: AAFObject, to clip: inout Clip, rate: AAFRational) {
        let fadeIn = (source.int64(AAFProperty.ID.fadeInLength)).flatMap { Self.time($0, rate) } ?? .zero
        let fadeOut = (source.int64(AAFProperty.ID.fadeOutLength)).flatMap { Self.time($0, rate) } ?? .zero
        guard fadeIn > .zero || fadeOut > .zero, fadeIn + fadeOut <= clip.duration else { return }
        var keyframes: [Keyframe<Double>] = []
        if fadeIn > .zero { keyframes += [Keyframe(time: .zero, value: 0), Keyframe(time: fadeIn, value: 1)] }
        if fadeOut > .zero {
            let end = clip.duration
            if fadeIn != end - fadeOut { keyframes.append(Keyframe(time: end - fadeOut, value: 1)) }
            keyframes.append(Keyframe(time: end, value: 0))
        }
        clip.volume = Animatable(1, keyframes: keyframes)
    }

    /// The slot a source clip refers to, by its ID; failing that, the first
    /// slot of the same kind.
    private static func slot(_ id: Int64, of mob: AAFObject, kind: Track.Kind, importer: AAFImporter) -> AAFObject? {
        let slots = mob.strongReferences(AAFProperty.ID.slots)
        return slots.first { $0.integer(AAFProperty.ID.slotID) == id }
            ?? slots.first { slot in
                slot.strongReference(AAFProperty.ID.segment).flatMap(importer.dataKind(of:)) == kind
            }
    }

    private struct Source {
        var item: MediaItem
        /// Where the clip starts in the file.
        var start: CMTime
    }

    /// Follows a source clip down from a master mob, through source mobs,
    /// to the file it plays: the first source mob with a URL, or failing
    /// that, the first file source mob, as media to relink.
    private mutating func resolve(_ mob: AAFObject, slotID: Int64, offset start: CMTime) -> Source? {
        var current = mob
        var slotID = slotID
        var offset = start
        var visited: Set<Int> = []
        var masterName = currentMasterName
        var fallback: (mob: AAFObject, start: CMTime)?

        for _ in 0..<Self.maximumDepth {
            guard visited.insert(current.entry).inserted else { break }
            let slots = current.strongReferences(AAFProperty.ID.slots)
            guard let slot = slots.first(where: { $0.integer(AAFProperty.ID.slotID) == slotID }) else { break }
            let rate = Self.validRate(slot.rational(AAFProperty.ID.editRate)) ?? AAFRational(numerator: 25, denominator: 1)
            let origin = Self.time(slot.int64(AAFProperty.ID.origin) ?? 0, rate) ?? .zero
            let position = offset + origin

            if current.isKind(of: AAFClass.masterMob), masterName == nil {
                masterName = current.string(AAFProperty.ID.mobName)
            }
            if current.isKind(of: AAFClass.sourceMob) {
                let descriptor = current.strongReference(AAFProperty.ID.essenceDescription)
                if let descriptor, locatorURL(of: descriptor) != nil {
                    let item = mediaItem(for: current, name: masterName)
                    return Source(item: item, start: fileTime(position, in: current, duration: item.metadata.duration))
                }
                // Tapes and film have nothing to relink to.
                let isPhysical = descriptor.map {
                    $0.isKind(of: AAFClass.tapeDescriptor) || $0.isKind(of: AAFClass.filmDescriptor)
                } ?? false
                if fallback == nil, !isPhysical { fallback = (current, position) }
            }

            guard let segment = slot.strongReference(AAFProperty.ID.segment),
                  let found = sourceClip(in: segment, at: position, rate: rate, depth: 0),
                  let next = found.clip.mobID(AAFProperty.ID.sourceID), !next.isZero, let nextMob = mobs[next] else { break }
            offset = (Self.time(found.clip.int64(AAFProperty.ID.startTime) ?? 0, rate) ?? .zero) + (position - found.start)
            slotID = found.clip.integer(AAFProperty.ID.sourceMobSlotID) ?? 0
            current = nextMob
        }
        if let fallback {
            return Source(item: mediaItem(for: fallback.mob, name: masterName), start: fallback.start)
        }
        // Nothing below the master mob: media known only by name, played
        // from where the clip starts in the master, not in a tape under it.
        guard mob.isKind(of: AAFClass.masterMob) || mob.isKind(of: AAFClass.sourceMob) else { return nil }
        return Source(item: mediaItem(for: mob, name: masterName), start: start)
    }

    /// A time in a file's source mob as a time in the file. Some
    /// applications count a file's slots from its timecode, as they do a
    /// tape's: past the file's end, a time is taken from its start timecode.
    private func fileTime(_ position: CMTime, in mob: AAFObject, duration: CMTime) -> CMTime {
        guard duration > .zero, position > duration else { return position }
        for slot in mob.strongReferences(AAFProperty.ID.slots) {
            guard let rate = Self.validRate(slot.rational(AAFProperty.ID.editRate)),
                  let segment = slot.strongReference(AAFProperty.ID.segment) else { continue }
            let timecode = segment.isKind(of: AAFClass.timecode) ? segment
                : segment.strongReferences(AAFProperty.ID.components).first { $0.isKind(of: AAFClass.timecode) }
            guard let start = timecode?.int64(AAFProperty.ID.timecodeStart).flatMap({ Self.time($0, rate) }) else { continue }
            let adjusted = position - start
            if adjusted >= .zero, adjusted <= duration { return adjusted }
        }
        return position
    }

    /// The source clip that plays at a time in a slot, and where it starts.
    private func sourceClip(
        in segment: AAFObject, at time: CMTime, rate: AAFRational, depth: Int
    ) -> (clip: AAFObject, start: CMTime)? {
        guard depth < Self.maximumDepth else { return nil }
        if segment.isKind(of: AAFClass.sourceClip) { return (segment, .zero) }
        if segment.isKind(of: AAFClass.sequence) {
            var position: Int64 = 0
            for component in segment.strongReferences(AAFProperty.ID.components) {
                let length = Self.length(of: component)
                if component.isKind(of: AAFClass.transition) {
                    let (start, overflow) = position.subtractingReportingOverflow(length)
                    guard !overflow else { return nil }
                    position = start
                    continue
                }
                let (next, overflow) = position.addingReportingOverflow(length)
                guard !overflow, let start = Self.time(position, rate), let end = Self.time(next, rate) else { return nil }
                if time >= start, time < end || length == 0 && time == start,
                   let found = sourceClip(in: component, at: time - start, rate: rate, depth: depth + 1) {
                    return (found.clip, start + found.start)
                }
                position = next
            }
            return nil
        }
        let inner = segment.strongReferences(AAFProperty.ID.choices).first
            ?? segment.strongReference(AAFProperty.ID.selected)
            ?? segment.strongReferences(AAFProperty.ID.inputSegments).first
        return inner.flatMap { sourceClip(in: $0, at: time, rate: rate, depth: depth + 1) }
    }

    // MARK: - Media

    /// The file a source mob's descriptor locates, if any.
    private func locatorURL(of descriptor: AAFObject) -> URL? {
        let descriptors = [descriptor] + subDescriptors(of: descriptor)
        for descriptor in descriptors {
            for locator in descriptor.strongReferences(AAFProperty.ID.locators) {
                if let url = ImportedMedia.url(from: locator.string(AAFProperty.ID.urlString), relativeTo: baseURL) {
                    return url
                }
            }
        }
        return nil
    }

    /// A multiple descriptor's own descriptors, one for each track of the
    /// file, under a property whose ID the file gives out.
    private func subDescriptors(of descriptor: AAFObject) -> [AAFObject] {
        guard descriptor.isKind(of: AAFClass.multipleDescriptor) else { return [] }
        return descriptor.allStrongReferenceVectors.filter { $0.isKind(of: AAFClass.essenceDescriptor) }
    }

    private mutating func mediaItem(for mob: AAFObject, name: String?) -> MediaItem {
        let id = mob.mobID(AAFProperty.ID.mobID) ?? MobID(bytes: [])
        if let item = mediaItems[id] { return item }
        let descriptor = mob.strongReference(AAFProperty.ID.essenceDescription)
        let descriptors = descriptor.map { [$0] + subDescriptors(of: $0) } ?? []
        let url = descriptor.flatMap(locatorURL(of:))
        let mobName = mob.string(AAFProperty.ID.mobName).flatMap { $0.isEmpty ? nil : $0 }
        let itemName = name.flatMap { $0.isEmpty ? nil : $0 } ?? mobName ?? url?.lastPathComponent ?? "Media"

        let slotKinds = mob.strongReferences(AAFProperty.ID.slots).compactMap { slot in
            slot.strongReference(AAFProperty.ID.segment).flatMap(dataKind(of:))
        }
        let picture = descriptors.first { $0.isKind(of: AAFClass.digitalImageDescriptor) || $0.has(AAFProperty.ID.storedWidth) }
        let sound = descriptors.first { $0.isKind(of: AAFClass.soundDescriptor) || $0.has(AAFProperty.ID.channels) }
        let hasPicture = picture != nil || slotKinds.contains(.video)
        let fileType = url.flatMap { UTType(filenameExtension: $0.pathExtension) }
        let isImage = fileType?.conforms(to: .image) ?? false
        let kind: MediaItem.Kind = isImage ? .image : hasPicture ? .video : .audio

        var metadata = MediaMetadata()
        for descriptor in descriptors where !isImage {
            guard let rate = Self.validRate(descriptor.rational(AAFProperty.ID.sampleRate)) else { continue }
            if descriptor.entry == picture?.entry { metadata.nominalFrameRate = Double(rate.numerator) / Double(rate.denominator) }
            if let length = descriptor.int64(AAFProperty.ID.fileLength), let duration = Self.time(length, rate) {
                metadata.duration = max(metadata.duration, duration)
            }
        }
        if let picture {
            let width = picture.integer(AAFProperty.ID.displayWidth) ?? picture.integer(AAFProperty.ID.storedWidth) ?? 0
            let height = picture.integer(AAFProperty.ID.displayHeight) ?? picture.integer(AAFProperty.ID.storedHeight) ?? 0
            if width > 0, height > 0, width < 100_000, height < 100_000 {
                metadata.naturalSize = CGSize(width: Double(width), height: Double(height))
                if !hasRenderSize {
                    settings.renderSize = metadata.naturalSize
                    hasRenderSize = true
                }
            }
        }
        let soundSlots = slotKinds.filter { $0 == .audio }.count
        if !isImage, sound != nil || soundSlots > 0 {
            let channels = sound?.integer(AAFProperty.ID.channels).map { Int(clamping: $0) } ?? 0
            metadata.audioChannelCount = max(1, min(channels, 64), min(soundSlots, 64))
            if let rate = Self.validRate(sound?.rational(AAFProperty.ID.audioSamplingRate)) {
                metadata.audioSampleRate = Double(rate.numerator) / Double(rate.denominator)
            } else {
                metadata.audioSampleRate = 48000
            }
        }
        let item = media.item(key: id.hex, url: url, name: itemName, kind: kind, metadata: metadata)
        mediaItems[id] = item
        return item
    }

    // MARK: - Effects

    /// AAF's own effects, by name, for files that leave their names out.
    private static let operationNames: [AUID: String] = [
        AAFDefinition.videoDissolve: "Video Dissolve", AAFDefinition.monoAudioDissolve: "Audio Dissolve",
        AAFDefinition.stereoAudioDissolve: "Audio Dissolve", AAFDefinition.videoSpeedControl: "Speed Control",
        AAFDefinition.monoAudioGain: "Audio Gain", AAFDefinition.stereoAudioGain: "Audio Gain",
        AAFDefinition.monoAudioPan: "Audio Pan",
    ]

    private func operationName(_ group: AAFObject) -> String {
        let id = group.weakReferenceKey(AAFProperty.ID.operation).flatMap { AUID(bytes: $0) }
        return id.flatMap { definitionNames[$0] ?? Self.operationNames[$0] } ?? id.map(\.description) ?? "Effect"
    }

    private mutating func importOperationGroup(_ group: AAFObject, at position: Int64, length: Int64, context: Context, depth: Int) {
        guard let start = context.timeline(position), let duration = Self.time(length, context.rate), duration > .zero else {
            return
        }
        let operation = group.weakReferenceKey(AAFProperty.ID.operation).flatMap { AUID(bytes: $0) }
        let name = operationName(group)
        let lowercasedName = name.lowercased()
        let inputs = group.strongReferences(AAFProperty.ID.inputSegments)
        let parameters = group.strongReferences(AAFProperty.ID.parameters)
        func parameter(_ id: AUID, named wanted: String) -> AAFObject? {
            parameters.first { parameter in
                guard let definition = parameter.auid(AAFProperty.ID.parameterDefinition) else { return false }
                // Premiere names them "Amplitude multiplier" and "Pan value".
                return definition == id
                    || definitionNames[definition]?.lowercased().replacingOccurrences(of: " ", with: "").hasPrefix(wanted) == true
            }
        }
        /// A parameter's value where it doesn't change: nil if it changes,
        /// or isn't a number.
        func constant(_ parameter: AAFObject?) -> Double? {
            guard let parameter, parameter.isKind(of: AAFClass.constantValue) || parameter.has(AAFProperty.ID.value) else {
                return nil
            }
            return parameter.indirectNumber(AAFProperty.ID.value)
        }

        var inner = context
        let range = CMTimeRange(start: start, duration: duration)
        inner.window = context.window.map { $0.intersection(range) } ?? range
        inner.lengthOverride = nil
        let first = clips.count
        let speed = parameter(AAFDefinition.speedRatio, named: "speedratio")
        let mainInput = inputs.first { !isEmpty($0, depth: depth) }
        let mainName = clipName(mainInput.flatMap { firstSourceClip(in: $0, depth: depth) })

        if operation.map(timeWarps.contains) == true || operation == AAFDefinition.videoSpeedControl || speed != nil {
            // Played at normal speed, for as long as the effect lasts.
            let ratio = constant(speed)
            if ratio.map({ abs($0 - 1) > 0.0001 }) ?? true {
                report.add(.speedChange, clipName: mainName, time: start)
            }
            inner.lengthOverride = length
            if let input = inputs.first { importSegment(input, at: position, context: inner, depth: depth + 1) }
            return
        }
        // A file's channels, combined, and a collapsed track's layers:
        // each input on a lane of its own.
        if lowercasedName.contains("channel combiner") || lowercasedName.contains("submaster") {
            importLayers(inputs, at: position, context: inner, depth: depth)
            return
        }
        guard !inputs.isEmpty else {
            report.add(.generator(name: name), time: start)
            return
        }
        // Avid's keys and titles take what's under them as their first
        // input, by a scope reference; the picture of their own is next.
        if let mainInput { importSegment(mainInput, at: position, context: inner, depth: depth + 1) }
        let added = first..<clips.count

        let isGain = operation == AAFDefinition.monoAudioGain || operation == AAFDefinition.stereoAudioGain
            || (context.kind == .audio && lowercasedName.contains("gain"))
        let isPan = operation == AAFDefinition.monoAudioPan || (context.kind == .audio && lowercasedName.contains("pan"))
        if isGain {
            guard let level = curve(parameter(AAFDefinition.amplitude, named: "amplitude")) else {
                // Avid's own gain, with no level AAF defines.
                report.add(.setting(name: name), clipName: mainName, time: start)
                return
            }
            for index in added {
                let gain = animatable(level, over: range, on: clips[index].clip) { max(0, $0) }
                clips[index].clip.volume = Self.product(clips[index].clip.volume, gain)
            }
            return
        }
        if isPan {
            guard let pan = curve(parameter(AAFDefinition.pan, named: "pan")) else {
                report.add(.setting(name: name), clipName: mainName, time: start)
                return
            }
            for index in added where clips[index].kind == .audio {
                // AAF pans from 0, left, to 1, right.
                let position = animatable(pan, over: range, on: clips[index].clip) { max(-1, min(1, $0 * 2 - 1)) }
                guard position.isAnimated || abs(position.value) > 0.0001 else { continue }
                var parameters = Pan()
                parameters.position = position
                clips[index].clip.effects.append(Effect(.pan(parameters)))
            }
            return
        }
        // Anything else is kept on its clips, turned off.
        report.add(.unsupportedEffect(name: name), clipName: mainName, time: start)
        let effect = UnsupportedEffect(
            format: InterchangeFormat.aaf.rawValue, identifier: operation?.description ?? "", name: name,
            isVideo: context.kind == .video,
            parameters: parameters.map { parameter in
                let definition = parameter.auid(AAFProperty.ID.parameterDefinition)
                return .init(
                    name: definition.flatMap { definitionNames[$0] } ?? definition?.description ?? "",
                    key: definition?.description,
                    value: constant(parameter).map { String($0) },
                    isAnimated: parameter.isKind(of: AAFClass.varyingValue)
                )
            }
        )
        for index in added { clips[index].clip.effects.append(Effect(isEnabled: false, .unsupported(effect))) }
    }

    /// A parameter's value as points along its effect, from 0 at its start
    /// to 1 at its end: one point for a constant value. Nil if it isn't a
    /// number.
    private func curve(_ parameter: AAFObject?) -> [(fraction: Double, value: Double)]? {
        guard let parameter else { return nil }
        if let value = parameter.indirectNumber(AAFProperty.ID.value), value.isFinite { return [(0, value)] }
        let points = parameter.strongReferences(AAFProperty.ID.pointList).compactMap { point -> (Double, Double)? in
            guard let time = point.rational(AAFProperty.ID.controlPointTime), time.denominator != 0,
                  let value = point.indirectNumber(AAFProperty.ID.controlPointValue), value.isFinite else { return nil }
            return (Double(time.numerator) / Double(time.denominator), value)
        }
        return points.isEmpty ? nil : points.sorted { $0.0 < $1.0 }
    }

    /// A curve over an effect's stretch of the timeline as a clip's
    /// parameter, keyframed from the clip's start where it changes there.
    private func animatable(
        _ curve: [(fraction: Double, value: Double)], over range: CMTimeRange, on clip: Clip, _ transform: (Double) -> Double
    ) -> Animatable<Double> {
        func value(at fraction: Double) -> Double {
            guard let first = curve.first, let last = curve.last else { return 0 }
            if fraction <= first.fraction { return first.value }
            if fraction >= last.fraction { return last.value }
            let index = curve.lastIndex { $0.fraction <= fraction }!
            let (from, to) = (curve[index], curve[index + 1])
            let span = to.fraction - from.fraction
            return span > 0 ? from.value + (to.value - from.value) * (fraction - from.fraction) / span : to.value
        }
        let length = range.duration.seconds
        guard length > 0 else { return Animatable(transform(curve.first?.value ?? 0)) }
        let offset = (clip.timelineStart - range.start).seconds
        let duration = clip.duration.seconds
        // The clip's ends, and the points between them.
        var times = [0.0, duration]
        times += curve.map { $0.fraction * length - offset }.filter { $0 > 0 && $0 < duration }
        times.sort()
        let values = times.map { transform(value(at: ($0 + offset) / length)) }
        guard let firstValue = values.first, values.contains(where: { abs($0 - firstValue) > 0.000_001 }) else {
            return Animatable(transform(value(at: offset / length)))
        }
        let timescale = max(clip.duration.timescale, 600)
        return Animatable(firstValue, keyframes: zip(times, values).map { time, value in
            Keyframe(time: CMTime(seconds: time, preferredTimescale: timescale), value: value)
        })
    }

    /// Two levels applied one after the other.
    private static func product(_ a: Animatable<Double>, _ b: Animatable<Double>) -> Animatable<Double> {
        guard a.isAnimated || b.isAnimated else { return Animatable(a.value * b.value) }
        let times = Set(a.keyframes.map(\.time) + b.keyframes.map(\.time)).sorted()
        return Animatable(a.value * b.value, keyframes: times.map { time in
            Keyframe(time: time, value: a.value(at: time) * b.value(at: time))
        })
    }

    /// The name of the clip an effect is on, for the report.
    private func clipName(_ segment: AAFObject?) -> String? {
        guard let segment, let id = segment.mobID(AAFProperty.ID.sourceID) else { return nil }
        return mobs[id]?.string(AAFProperty.ID.mobName)
    }

    // MARK: - Markers

    /// Comment and descriptive markers, alone or in a sequence, where their
    /// positions in the slot fall on the timeline. A nested timeline's
    /// markers are kept only where it's shown.
    private mutating func importMarkers(_ segment: AAFObject, context: Context, depth: Int) {
        guard depth < Self.maximumDepth else { return }
        if segment.isKind(of: AAFClass.sequence) {
            for component in segment.strongReferences(AAFProperty.ID.components) {
                importMarkers(component, context: context, depth: depth + 1)
            }
            return
        }
        guard segment.isKind(of: AAFClass.event) || segment.has(AAFProperty.ID.position),
              let position = segment.int64(AAFProperty.ID.position), position >= 0,
              let time = context.timeline(position), time >= .zero,
              context.window.map({ $0.containsTime(time) }) ?? true else { return }
        markers.append(Marker(time: time, name: segment.string(AAFProperty.ID.comment) ?? ""))
    }

    // MARK: - Tracks

    /// The clips onto tracks. A picture clip and sound clips of the same
    /// file, in step, become one clip that plays both; a picture whose
    /// sound isn't in step has its audio detached. A file's channels each
    /// on their own track are one clip, as Montage plays a file's sound
    /// whole.
    private mutating func assembleTracks() -> [Track] {
        func inStep(_ a: Clip, _ b: Clip) -> Bool {
            a.mediaID == b.mediaID && a.timelineStart == b.timelineStart && a.duration == b.duration
                && a.sourceRange.start == b.sourceRange.start
        }
        var merged: Set<Int> = []
        for index in clips.indices where clips[index].kind == .video {
            let mediaID = clips[index].clip.mediaID
            guard let item = media.items.first(where: { $0.id == mediaID }), item.kind == .video else { continue }
            let matches = clips.indices.filter { other in
                clips[other].kind == .audio && !merged.contains(other) && inStep(clips[other].clip, clips[index].clip)
            }
            if let first = matches.first {
                merged.formUnion(matches)
                clips[index].clip.volume = clips[first].clip.volume
                clips[index].clip.effects += clips[first].clip.effects.filter(\.kind.isAudioEffect)
            } else if item.metadata.hasAudio {
                clips[index].clip.isAudioDetached = true
            }
        }
        for index in clips.indices where clips[index].kind == .audio && !merged.contains(index) {
            for other in clips.indices where other > index && clips[other].kind == .audio && !merged.contains(other)
                && inStep(clips[other].clip, clips[index].clip) {
                merged.insert(other)
            }
        }

        var assembler = TimelineAssembler()
        for transition in transitions { assembler.addTransition(transition.range, lane: transition.lane) }
        for (index, pending) in clips.enumerated() where !merged.contains(index) {
            assembler.add(pending.clip, kind: pending.kind, lane: pending.lane, name: pending.name)
        }
        return assembler.tracks(report: &report)
    }

    // MARK: - Times

    private static func validRate(_ rate: AAFRational?) -> AAFRational? {
        guard let rate, rate.numerator > 0, rate.denominator > 0 else { return nil }
        return rate
    }

    private static func length(of component: AAFObject) -> Int64 {
        max(0, component.int64(AAFProperty.ID.length) ?? 0)
    }

    /// A count of edit units as a time, exactly; nil if it's too long to hold.
    fileprivate static func time(_ units: Int64, _ rate: AAFRational) -> CMTime? {
        guard rate.numerator > 0, rate.denominator > 0 else { return nil }
        let (value, overflow) = units.multipliedReportingOverflow(by: Int64(rate.denominator))
        return overflow ? nil : InterchangeTime.time(value, over: Int64(rate.numerator))
    }
}

private extension Effect.Kind {
    var isAudioEffect: Bool {
        if case .pan = self { true } else { false }
    }
}
