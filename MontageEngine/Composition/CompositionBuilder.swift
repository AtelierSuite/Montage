import AVFoundation
import CoreGraphics
import CoreMedia

/// Turns a project into the AVFoundation objects that play and export it:
///
/// ```
/// Project ─► CompositionBuilder ─► AVComposition       (what plays when)
///                                  AVVideoComposition  (where each picture goes)
///                                  AVAudioMix          (how each clip sounds)
/// ```
///
/// Each video track of the timeline that isn't hidden becomes a composition
/// video track, a layer, and every track that isn't muted an audio track: a
/// video clip's own sound goes on its track's audio track unless it has been
/// detached, and an audio track's clips go on its own. Clips are cut out of
/// their media with `insertTimeRange`, and gaps between them are empty time,
/// which draws black and plays silence. Stills, text and shapes are placed
/// with filler that the compositor draws them over (see `StillFiller`), and
/// have no sound. Each audio track of the composition
/// has a tap that runs its clips' audio effects (see `audioTail(for:)` for
/// the room left for them to ring out).
///
/// The video composition draws with `VideoCompositor`, which stacks the
/// layers bottom to top and evaluates each clip's transform, opacity, blend
/// mode and effects every frame. It reads them from `snapshot`, so edits to
/// them show without a rebuild; only what's placed where is fixed here.
/// Keyframed volume is followed with the audio mix's straight ramps.
public struct CompositionBuilder: Sendable {
    public var project: Project
    public var mediaResolver: MediaResolver
    /// Where the compositor reads clip parameters and the audio taps read
    /// the clips' effects as they're edited, such as the playback
    /// controller's, so changes show and are heard without a rebuild. Nil
    /// reads them from `project` as it is, for a composition that shouldn't
    /// follow edits, such as an export's.
    public var snapshot: ProjectSnapshot?
    /// Whether frames may be rendered with the GPU.
    public var usesGPU = true
    /// The most video layers that show at once; clips past it are left out
    /// as `.tooManyLayers`, top layers first.
    public var maximumVideoLayers = VideoLayerLimit.standard
    /// Whether large video plays from its proxy, where one has been made, as
    /// preview may choose to. Export always uses the originals.
    public var usesProxies = false

    public init(project: Project, mediaResolver: MediaResolver, snapshot: ProjectSnapshot? = nil) {
        self.project = project
        self.mediaResolver = mediaResolver
        self.snapshot = snapshot
    }

    /// How long a clip's sound keeps going after the clip ends, such as a
    /// reverb or delay ringing out, so the composition can leave room for it.
    ///
    /// The room is kept on the clip's composition track: the next clip on the
    /// same timeline track that starts before the tail is over goes on a
    /// composition track of its own, so nothing on the timeline moves. A tail
    /// runs on into empty time, or, after a track's last clip, into filler
    /// that the clip's tap silences, since a composition track can't end in
    /// empty time. A tail still ringing after the last clip of the timeline
    /// makes the composition longer than the project, so it isn't cut off.
    public static func audioTail(for clip: Clip) -> CMTime {
        clip.audioTail
    }

    /// Builds the composition. Clips whose media can't be found or used are
    /// left out as empty time and listed in `skippedClips`; only cancelling
    /// the task throws. Runs off the caller's actor, so the main actor can
    /// call it without waiting on the media being opened.
    @concurrent
    public func build() async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        var media = MediaLoader(resolver: mediaResolver, usesProxies: usesProxies)
        var skipped: [SkippedClip] = []
        var pictures: [LayerWriter] = []
        var sounds: [LayerWriter] = []
        let overLimit = VideoLayerLimit.clipsOverLimit(in: project, limit: maximumVideoLayers)

        for track in project.tracks {
            let wantsPicture = track.kind == .video && !track.isHidden
            let wantsSound = !track.isMuted
            guard wantsPicture || wantsSound else { continue }
            var picture = wantsPicture ? LayerWriter(kind: .video, trackID: track.id) : nil
            // Where each clip placed on the picture's frames come from, for
            // the handles its transitions show.
            var pictureSources: [Clip.ID: PictureSource] = [:]
            // The track's sound, on as many composition tracks as it takes
            // to keep clips out of the tails of the ones before them.
            var sound: [LayerWriter] = []
            func placeSound(_ clip: Clip, from audio: SourceTrack) throws -> Bool {
                guard wantsSound else { return true }
                let lane = sound.firstIndex { $0.ringsUntil <= clip.timelineStart } ?? {
                    sound.append(LayerWriter(kind: .audio, trackID: track.id))
                    return sound.count - 1
                }()
                return try sound[lane].place(clip, from: audio, in: composition, settings: project.settings)
            }

            for clip in track.clips {
                try Task.checkCancellation()
                func skip(_ reason: SkippedClip.Reason) {
                    skipped.append(SkippedClip(clipID: clip.id, mediaID: clip.mediaID, reason: reason))
                }

                // Text and shapes have no media: like stills, they're placed
                // with filler, and the compositor draws them over it.
                if clip.content.isGenerated {
                    if track.kind != .video {
                        skip(.noUsableTrack)
                    } else if picture != nil {
                        switch await media.loadFiller() {
                        case .success(let filler):
                            do {
                                if try !picture!.place(clip, drawing: .drawn, naturalSize: .zero, filler: filler, in: composition) {
                                    skip(.outsideMedia)
                                } else {
                                    pictureSources[clip.id] = .drawn(.drawn, naturalSize: .zero, filler: filler)
                                }
                            } catch {
                                skip(.unreadable)
                            }
                        case .failure(let failure):
                            skip(failure.reason)
                        }
                    }
                    continue
                }
                guard let item = project.mediaItem(id: clip.mediaID) else {
                    skip(.mediaNotInProject)
                    continue
                }
                if item.kind == .image {
                    // A still has no sound, and only shows on a video track.
                    guard track.kind == .video else {
                        skip(.noUsableTrack)
                        continue
                    }
                    guard picture != nil else { continue }
                    let still: (image: StillImage, filler: SourceTrack)
                    switch await media.loadStill(item) {
                    case .success(let loaded): still = loaded
                    case .failure(let failure):
                        skip(failure.reason)
                        continue
                    }
                    do {
                        if try !picture!.place(clip, drawing: .still(still.image), naturalSize: still.image.size,
                                               filler: still.filler, in: composition) {
                            skip(.outsideMedia)
                        } else {
                            pictureSources[clip.id] = .drawn(.still(still.image), naturalSize: still.image.size, filler: still.filler)
                        }
                    } catch {
                        skip(.unreadable)
                    }
                    continue
                }
                let source: LoadedMedia
                switch await media.load(item) {
                case .success(let loaded): source = loaded
                case .failure(let failure):
                    skip(failure.reason)
                    continue
                }

                do {
                    switch track.kind {
                    case .video:
                        guard let video = source.video else {
                            skip(.noUsableTrack)
                            continue
                        }
                        if picture != nil {
                            if overLimit.contains(clip.id) {
                                // Its sound still plays.
                                skip(.tooManyLayers)
                            } else if try !picture!.place(clip, from: video, in: composition, settings: project.settings) {
                                skip(.outsideMedia)
                                continue
                            } else {
                                pictureSources[clip.id] = .video(video)
                            }
                        }
                        if !clip.isAudioDetached, let audio = source.audio {
                            _ = try placeSound(clip, from: audio)
                        }
                    case .audio:
                        guard let audio = source.audio else {
                            skip(.noUsableTrack)
                            continue
                        }
                        if try placeSound(clip, from: audio) == false {
                            skip(.outsideMedia)
                        }
                    }
                } catch {
                    skip(.unreadable)
                }
            }
            if let picture, picture.compositionTrack != nil {
                pictures.append(picture)
                // The track's transitions, on a layer of their own just over it.
                if let handles = try placeHandles(of: track, sources: pictureSources, in: composition) {
                    pictures.append(handles)
                }
            }
            sounds += sound.filter { $0.compositionTrack != nil }
        }

        let writers = pictures + sounds
        guard !writers.isEmpty else {
            return BuiltComposition(
                project: project, composition: AVComposition(), videoComposition: nil, audioMix: nil,
                duration: .zero, videoLayers: [], audioLayers: [], skippedClips: skipped
            )
        }
        // A composition can't end in empty time, so it runs to the end of
        // the last clip placed: clips left out at the end shorten it. A tail
        // still ringing there runs on past it, over a black picture, so a
        // reverb or delay on the last clip isn't cut off.
        let lastClipEnd = writers.map(\.cursor).max() ?? .zero
        let end = max(lastClipEnd, sounds.map(\.ringsUntil).max() ?? .zero)
        for index in sounds.indices {
            try sounds[index].fillTail(before: end)
        }

        var meters: [Clip.ID: AudioMeter] = [:]
        let audioMix = sounds.isEmpty ? nil : audioMix(for: sounds, duration: end, meters: &meters)
        return BuiltComposition(
            project: project,
            composition: composition.copy() as! AVComposition,
            videoComposition: pictures.isEmpty ? nil : videoComposition(for: pictures, duration: end),
            audioMix: audioMix,
            duration: end,
            videoLayers: pictures.map(\.layer),
            audioLayers: sounds.map(\.layer),
            skippedClips: skipped,
            audioLevels: AudioLevels(meters)
        )
    }

    /// One instruction for each stretch of the timeline between the points
    /// where a clip starts or ends, holding the layers showing through it,
    /// bottom layer first, drawn over black by the custom compositor.
    private func videoComposition(for layers: [LayerWriter], duration: CMTime) -> AVVideoComposition {
        var cuts = Set([CMTime.zero, duration])
        for layer in layers {
            for segment in layer.layer.segments {
                cuts.insert(segment.timelineRange.start)
                cuts.insert(segment.timelineRange.end)
            }
        }
        let times = cuts.filter { $0 <= duration }.sorted()
        let snapshot = self.snapshot ?? ProjectSnapshot(project)
        let instructions = zip(times, times.dropFirst()).map { start, end in
            var showing = layers.compactMap { $0.placement(at: start) }
            // A transition's handle shows with the clip it meets, the layer
            // just under it, and the two are mixed.
            for index in showing.indices.dropFirst() {
                guard let transition = showing[index].transition, showing[index - 1].transition == nil,
                      showing[index - 1].clip.id != showing[index].clip.id else { continue }
                showing[index - 1].transition = transition
            }
            return CompositorInstruction(
                timeRange: CMTimeRange(start: start, end: end), layers: showing,
                snapshot: snapshot, renderSize: project.settings.renderSize, usesGPU: usesGPU
            )
        }
        return AVVideoComposition(configuration: AVVideoComposition.Configuration(
            customVideoCompositorClass: VideoCompositor.self,
            frameDuration: project.settings.frameDuration,
            instructions: instructions,
            renderSize: project.settings.renderSize
        ))
    }

    /// Each layer's volumes, and a tap that runs its clips' effects and
    /// meters them, adding their meters to `meters`.
    private func audioMix(for layers: [LayerWriter], duration: CMTime, meters: inout [Clip.ID: AudioMeter]) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        let snapshot = self.snapshot ?? ProjectSnapshot(project)
        mix.inputParameters = layers.compactMap { layer in
            guard let parameters = layer.audioParameters else { return nil }
            parameters.audioTapProcessor = AudioEffectsProcessor.tap(
                for: layer.layer, in: project, snapshot: snapshot, end: duration, meters: &meters
            )
            return parameters.copy() as? AVAudioMixInputParameters
        }
        return mix.copy() as! AVAudioMix
    }

    /// The frames a track's transitions show from beyond the ends of their
    /// clips, on a composition track of their own: over the stretch before
    /// each cut, the incoming clip's media from before its start, and after
    /// it, the outgoing clip's from after its end. Only transitions both of
    /// whose clips' pictures were placed play. Nil if none do.
    private func placeHandles(
        of track: Track, sources: [Clip.ID: PictureSource], in composition: AVMutableComposition
    ) throws -> LayerWriter? {
        var handles = LayerWriter(kind: .video, trackID: track.id)
        for placed in project.placedTransitions(on: track) {
            guard let from = sources[placed.outgoing.id], let to = sources[placed.incoming.id] else { continue }
            let transition = CompositorTransition(placed)
            let cut = placed.cut
            do {
                if placed.beforeCut > .zero {
                    try handles.placeHandle(
                        of: placed.incoming, over: CMTimeRange(start: cut - placed.beforeCut, end: cut), isIncoming: true,
                        from: to, frameDuration: project.settings.frameDuration, transition: transition, in: composition
                    )
                }
                if placed.afterCut > .zero {
                    try handles.placeHandle(
                        of: placed.outgoing, over: CMTimeRange(start: cut, end: cut + placed.afterCut), isIncoming: false,
                        from: from, frameDuration: project.settings.frameDuration, transition: transition, in: composition
                    )
                }
            } catch {
                // The transition cuts instead; what's placed of it so far shows
                // as a dissolve with nothing.
                continue
            }
        }
        return handles.compositionTrack == nil ? nil : handles
    }

    // MARK: - Fitting pictures

    /// Where a picture goes in the frame: turned upright by its track's
    /// preferred transform, fitted into the render size and centred, then
    /// scaled, turned clockwise and moved by the clip's transform at a time
    /// from the clip's start. In the video composition's coordinates, which
    /// start at the top left.
    static func layerTransform(
        naturalSize: CGSize, preferredTransform: CGAffineTransform, clipTransform: ClipTransform,
        renderSize: CGSize, at localTime: CMTime, fit: FrameFit = .fit
    ) -> CGAffineTransform {
        FrameComposer.fitTransform(
            naturalSize: naturalSize, preferredTransform: preferredTransform, renderSize: renderSize, fit: fit
        )
            .concatenating(FrameComposer.clipTransform(clipTransform, renderSize: renderSize, at: localTime))
    }
}

// MARK: - Building a layer

/// One timeline track's picture or sound, as it's laid into a composition
/// track clip by clip.
private struct LayerWriter {
    let kind: CompositionLayer.Kind
    let trackID: Track.ID
    /// Made when the first clip is placed, so a track with nothing to play
    /// adds nothing to the composition.
    private(set) var compositionTrack: AVMutableCompositionTrack?
    /// Where the composition track ends so far.
    private(set) var cursor = CMTime.zero
    private(set) var segments: [CompositionLayer.Segment] = []
    /// For a video layer, what the compositor needs of each segment's clip.
    private(set) var placements: [CompositorLayer] = []
    private(set) var audioParameters: AVMutableAudioMixInputParameters?
    /// Where the last clip's sound stops ringing on, after its tail. Earlier
    /// than `cursor` when it has none, so only a tail keeps clips away.
    private(set) var ringsUntil = CMTime.negativeInfinity
    /// What the last clip played, for filler to keep the track going under
    /// its tail.
    private var lastPlaced: (source: SourceTrack, range: CMTimeRange)?

    init(kind: CompositionLayer.Kind, trackID: Track.ID) {
        self.kind = kind
        self.trackID = trackID
    }

    var layer: CompositionLayer {
        CompositionLayer(kind: kind, trackID: trackID, compositionTrackID: compositionTrack?.trackID ?? kCMPersistentTrackID_Invalid, segments: segments)
    }

    /// The clip the compositor draws at a time, if one plays then.
    func placement(at time: CMTime) -> CompositorLayer? {
        segments.firstIndex { $0.timelineRange.start <= time && time < $0.timelineRange.end }
            .flatMap { placements.indices.contains($0) ? placements[$0] : nil }
    }

    /// Puts as much of a clip as its media has at the clip's place on the
    /// timeline, after empty time from the clip before, played at the clip's
    /// speed. False when none of the clip's source range is in the media.
    mutating func place(
        _ clip: Clip, from source: SourceTrack, in composition: AVMutableComposition, settings: ProjectSettings
    ) throws -> Bool {
        let speed = clip.speed
        var sourceRange = clip.sourceRange.intersection(source.timeRange)
        guard sourceRange.duration > .zero else { return false }
        var start = clip.timelineStart + speed.timelineDuration(ofMedia: sourceRange.start - clip.sourceRange.start)
        var duration = speed.timelineDuration(ofMedia: sourceRange.duration)
        // Clips on a track shouldn't overlap; if one does, the earlier clip
        // wins and the later one loses its front.
        if start < cursor {
            let overlap = cursor - start
            guard overlap < duration else { return false }
            let skipped = speed.mediaDuration(ofTimeline: overlap)
            sourceRange = CMTimeRange(start: sourceRange.start + skipped, duration: sourceRange.duration - skipped)
            duration = duration - overlap
            start = cursor
        }

        guard let compositionTrack = makeCompositionTrack(in: composition) else { return false }
        if start > cursor {
            compositionTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start))
        }
        try compositionTrack.insertTimeRange(sourceRange, of: source.track, at: start)
        if !speed.isNormal {
            compositionTrack.scaleTimeRange(CMTimeRange(start: start, duration: sourceRange.duration), toDuration: duration)
        }
        let timelineRange = CMTimeRange(start: start, duration: duration)
        cursor = timelineRange.end
        let tail = CompositionBuilder.audioTail(for: clip)
        ringsUntil = kind == .audio && tail > .zero ? cursor + tail : .negativeInfinity
        lastPlaced = (source, sourceRange)
        segments.append(CompositionLayer.Segment(clipID: clip.id, mediaID: clip.mediaID, timelineRange: timelineRange, sourceRange: sourceRange))

        switch kind {
        case .video:
            placements.append(CompositorLayer(
                source: .track(compositionTrack.trackID), clip: clip,
                naturalSize: source.naturalSize, preferredTransform: source.preferredTransform
            ))
        case .audio:
            let ramps = clip.volume.ramps(over: timelineRange, clipStart: clip.timelineStart)
            if ramps.isEmpty {
                audioParameters?.setVolume(Float(clip.volume.value(at: clip.localTime(start))), at: start)
            }
            for ramp in ramps {
                audioParameters?.setVolumeRamp(fromStartVolume: Float(ramp.start), toEndVolume: Float(ramp.end), timeRange: ramp.timeRange)
            }
        }
        return true
    }

    /// Puts a clip the compositor draws itself (a still, text or a shape) at
    /// its place on the timeline, after empty time from the clip before: the
    /// filler, stretched to the clip's length, holds its time, and the
    /// compositor draws the picture over it. False when an earlier clip
    /// covers all of it.
    mutating func place(
        _ clip: Clip, drawing source: CompositorLayer.Source, naturalSize: CGSize, filler: SourceTrack,
        in composition: AVMutableComposition
    ) throws -> Bool {
        var sourceRange = clip.sourceRange
        var start = clip.timelineStart
        if start < cursor {
            let overlap = cursor - start
            guard overlap < sourceRange.duration else { return false }
            sourceRange = CMTimeRange(start: sourceRange.start + overlap, duration: sourceRange.duration - overlap)
            start = cursor
        }
        guard sourceRange.duration > .zero, let compositionTrack = makeCompositionTrack(in: composition) else { return false }
        if start > cursor {
            compositionTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start))
        }
        let piece = min(sourceRange.duration, filler.timeRange.duration)
        try compositionTrack.insertTimeRange(CMTimeRange(start: filler.timeRange.start, duration: piece), of: filler.track, at: start)
        if piece < sourceRange.duration {
            compositionTrack.scaleTimeRange(CMTimeRange(start: start, duration: piece), toDuration: sourceRange.duration)
        }
        let timelineRange = CMTimeRange(start: start, duration: sourceRange.duration)
        cursor = timelineRange.end
        ringsUntil = .negativeInfinity
        lastPlaced = nil
        segments.append(CompositionLayer.Segment(clipID: clip.id, mediaID: clip.mediaID, timelineRange: timelineRange, sourceRange: sourceRange))
        placements.append(CompositorLayer(source: source, clip: clip, naturalSize: naturalSize, preferredTransform: .identity))
        return true
    }

    /// Puts frames from beyond one end of a clip, its handle, over a
    /// stretch of the timeline, for a transition: from before its start for
    /// the clip the transition goes to, from after its end for the one it
    /// comes from. Where the media runs out, the nearest frame it has is
    /// held for the rest. A still, text or shape is drawn on.
    mutating func placeHandle(
        of clip: Clip, over range: CMTimeRange, isIncoming: Bool, from source: PictureSource, frameDuration: CMTime,
        transition: CompositorTransition, in composition: AVMutableComposition
    ) throws {
        guard range.duration > .zero, range.start >= cursor, let compositionTrack = makeCompositionTrack(in: composition) else { return }
        if range.start > cursor {
            compositionTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: range.start))
        }
        // The media under the stretch, at the clip's speed.
        let length = clip.speed.mediaDuration(ofTimeline: range.duration)
        let wanted = isIncoming
            ? CMTimeRange(start: clip.sourceRange.start - length, duration: length)
            : CMTimeRange(start: clip.sourceRange.end, duration: length)
        let placement: CompositorLayer
        switch source {
        case .video(let video):
            let media = video.timeRange
            var available = wanted.intersection(media)
            if !available.isValid || available.duration < .zero { available = CMTimeRange(start: wanted.start, duration: .zero) }
            let held = length - available.duration
            /// A frame of the media, held for a while at a time on the timeline.
            func hold(_ time: CMTime, for duration: CMTime, at start: CMTime) throws {
                guard duration > .zero else { return }
                let latest = media.end - frameDuration
                let frameStart = max(media.start, min(time, latest))
                let frame = CMTimeRange(start: frameStart, duration: frameDuration).intersection(media)
                guard frame.isValid, frame.duration > .zero else {
                    compositionTrack.insertEmptyTimeRange(CMTimeRange(start: start, duration: duration))
                    return
                }
                try compositionTrack.insertTimeRange(frame, of: video.track, at: start)
                compositionTrack.scaleTimeRange(CMTimeRange(start: start, duration: frame.duration), toDuration: duration)
            }
            if isIncoming {
                let first = available.duration > .zero ? available.start : clip.sourceRange.start
                try hold(first, for: held, at: range.start)
                if available.duration > .zero {
                    try compositionTrack.insertTimeRange(available, of: video.track, at: range.start + held)
                }
            } else {
                if available.duration > .zero {
                    try compositionTrack.insertTimeRange(available, of: video.track, at: range.start)
                }
                let last = (available.duration > .zero ? available.end : clip.sourceRange.end) - frameDuration
                try hold(last, for: held, at: range.start + available.duration)
            }
            if length != range.duration {
                compositionTrack.scaleTimeRange(CMTimeRange(start: range.start, duration: length), toDuration: range.duration)
            }
            placement = CompositorLayer(
                source: .track(compositionTrack.trackID), clip: clip, naturalSize: video.naturalSize,
                preferredTransform: video.preferredTransform, transition: transition
            )
        case .drawn(let drawn, let naturalSize, let filler):
            let piece = min(range.duration, filler.timeRange.duration)
            try compositionTrack.insertTimeRange(CMTimeRange(start: filler.timeRange.start, duration: piece), of: filler.track, at: range.start)
            if piece < range.duration {
                compositionTrack.scaleTimeRange(CMTimeRange(start: range.start, duration: piece), toDuration: range.duration)
            }
            placement = CompositorLayer(
                source: drawn, clip: clip, naturalSize: naturalSize, preferredTransform: .identity, transition: transition
            )
        }
        cursor = range.end
        segments.append(CompositionLayer.Segment(clipID: clip.id, mediaID: clip.mediaID, timelineRange: range, sourceRange: wanted))
        placements.append(placement)
    }

    /// The composition track, made when the first clip is placed.
    private mutating func makeCompositionTrack(in composition: AVMutableComposition) -> AVMutableCompositionTrack? {
        if compositionTrack == nil {
            let mediaType: AVMediaType = kind == .video ? .video : .audio
            compositionTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            if let compositionTrack, kind == .audio {
                audioParameters = AVMutableAudioMixInputParameters(track: compositionTrack)
            }
        }
        return compositionTrack
    }

    /// Keeps the track going under the last clip's tail, as far as `end`.
    /// Empty time can't end a track, so it's filled with the clip's own
    /// media, stretched if it's shorter, which the clip's tap silences.
    mutating func fillTail(before end: CMTime) throws {
        guard let compositionTrack, let lastPlaced, ringsUntil > cursor else { return }
        let fill = min(ringsUntil, end) - cursor
        guard fill > .zero else { return }
        let piece = min(fill, lastPlaced.range.duration)
        try compositionTrack.insertTimeRange(CMTimeRange(start: lastPlaced.range.start, duration: piece), of: lastPlaced.source.track, at: cursor)
        if piece < fill {
            compositionTrack.scaleTimeRange(CMTimeRange(start: cursor, duration: piece), toDuration: fill)
        }
        cursor = cursor + fill
    }
}

/// Where a clip placed on a picture layer gets its frames.
private enum PictureSource {
    /// A video track's.
    case video(SourceTrack)
    /// The compositor draws them, over filler that holds the time.
    case drawn(CompositorLayer.Source, naturalSize: CGSize, filler: SourceTrack)
}

// MARK: - Loading media

/// A track of a media file, with what placing it needs to know.
private struct SourceTrack {
    let track: AVAssetTrack
    let timeRange: CMTimeRange
    let naturalSize: CGSize
    let preferredTransform: CGAffineTransform
}

private struct LoadedMedia {
    /// Kept for as long as their tracks are used: a track only holds on to
    /// its asset weakly, and can't be inserted once the asset is gone. The
    /// media's own, and any copy made from it played in its place.
    let assets: [AVURLAsset]
    let video: SourceTrack?
    let audio: SourceTrack?
}

private struct LoadFailure: Error {
    let reason: SkippedClip.Reason
}

/// Opens each media item's file once per build, however many clips use it.
private struct MediaLoader {
    let resolver: MediaResolver
    let usesProxies: Bool
    private var loaded: [MediaItem.ID: Result<LoadedMedia, LoadFailure>] = [:]
    private var stills: [MediaItem.ID: Result<StillImage, LoadFailure>] = [:]
    /// What still images are placed with, opened once per build.
    private var filler: Result<LoadedMedia, LoadFailure>?

    init(resolver: MediaResolver, usesProxies: Bool) {
        self.resolver = resolver
        self.usesProxies = usesProxies
    }

    mutating func load(_ item: MediaItem) async -> Result<LoadedMedia, LoadFailure> {
        if let result = loaded[item.id] { return result }
        let result = await Self.open(item, resolver: resolver, usesProxies: usesProxies)
        loaded[item.id] = result
        return result
    }

    /// A still image, and the filler to place its clip with.
    mutating func loadStill(_ item: MediaItem) async -> Result<(image: StillImage, filler: SourceTrack), LoadFailure> {
        let image: StillImage
        switch stills[item.id] ?? Self.openStill(item, resolver: resolver) {
        case .success(let opened):
            stills[item.id] = .success(opened)
            image = opened
        case .failure(let failure):
            stills[item.id] = .failure(failure)
            return .failure(failure)
        }
        return await loadFiller().map { (image, $0) }
    }

    /// The filler that stills, text and shapes are placed with, opened once
    /// per build.
    mutating func loadFiller() async -> Result<SourceTrack, LoadFailure> {
        if filler == nil {
            do {
                filler = await Self.open(try await StillFiller.shared.url())
            } catch {
                StillFiller.logger.error("Couldn't make the filler: \(error.localizedDescription, privacy: .public)")
                filler = .failure(LoadFailure(reason: .unreadable))
            }
        }
        switch filler! {
        case .success(let loaded):
            guard let video = loaded.video else { return .failure(LoadFailure(reason: .unreadable)) }
            return .success(video)
        case .failure(let failure): return .failure(failure)
        }
    }

    private static func openStill(_ item: MediaItem, resolver: MediaResolver) -> Result<StillImage, LoadFailure> {
        guard let url = resolver.url(for: item), (try? url.checkResourceIsReachable()) == true else {
            return .failure(LoadFailure(reason: .fileNotFound))
        }
        guard let image = StillImage(id: item.id, url: url) else { return .failure(LoadFailure(reason: .unreadable)) }
        return .success(image)
    }

    private static func open(_ item: MediaItem, resolver: MediaResolver, usesProxies: Bool) async -> Result<LoadedMedia, LoadFailure> {
        guard let url = resolver.url(for: item), (try? url.checkResourceIsReachable()) == true else {
            return .failure(LoadFailure(reason: .fileNotFound))
        }
        let opened = await open(url)
        guard case .success(let loaded) = opened else { return opened }
        var assets = loaded.assets, video = loaded.video, audio = loaded.audio
        do {
            // Mono sound plays from a stereo copy where there is one, so it
            // can be panned.
            if audio != nil, DerivedMedia.stereoAudio.applies(to: item),
               let stereo = await derivedTrack(.stereoAudio, of: item, mediaType: .audio, resolver: resolver) {
                assets.append(stereo.asset)
                audio = try await source(stereo.track)
            }
            // Large video's picture plays from its proxy, if asked to and
            // there is one; its sound is still the original's.
            if usesProxies, video != nil, DerivedMedia.proxy.applies(to: item),
               let proxy = await derivedTrack(.proxy, of: item, mediaType: .video, resolver: resolver) {
                assets.append(proxy.asset)
                video = try await source(proxy.track)
            }
        } catch {
            // A copy that can't be used leaves the original as it is.
            return .success(loaded)
        }
        return .success(LoadedMedia(assets: assets, video: video, audio: audio))
    }

    private static func open(_ url: URL) async -> Result<LoadedMedia, LoadFailure> {
        // Precise timing, so cuts land on the frames the timeline shows.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            let video = try await asset.loadTracks(withMediaType: .video).first
            // Phones add extra audio tracks, such as spatial audio, that are
            // turned off; the main one is the first that's on.
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            var audio = audioTracks.first
            for track in audioTracks where try await track.load(.isEnabled) {
                audio = track
                break
            }
            guard video != nil || audio != nil else { return .failure(LoadFailure(reason: .unreadable)) }
            return .success(LoadedMedia(assets: [asset], video: try await source(video), audio: try await source(audio)))
        } catch {
            return .failure(LoadFailure(reason: .unreadable))
        }
    }

    /// The first track of a kind in a copy made from an item's media, if
    /// one's been made and can be read.
    private static func derivedTrack(
        _ kind: DerivedMedia, of item: MediaItem, mediaType: AVMediaType, resolver: MediaResolver
    ) async -> (asset: AVURLAsset, track: AVAssetTrack)? {
        guard let url = resolver.url(for: item, kind), (try? url.checkResourceIsReachable()) == true else { return nil }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let track = try? await asset.loadTracks(withMediaType: mediaType).first else { return nil }
        return (asset, track)
    }

    private static func source(_ track: AVAssetTrack?) async throws -> SourceTrack? {
        guard let track else { return nil }
        // Inserting a track needs its format descriptions loaded, or it fails.
        let (timeRange, naturalSize, preferredTransform, _) = try await track.load(
            .timeRange, .naturalSize, .preferredTransform, .formatDescriptions
        )
        return SourceTrack(track: track, timeRange: timeRange, naturalSize: naturalSize, preferredTransform: preferredTransform)
    }
}
