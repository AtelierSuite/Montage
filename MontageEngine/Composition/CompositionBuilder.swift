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
/// which draws black and plays silence. Each audio track of the composition
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

                guard let item = project.mediaItem(id: clip.mediaID) else {
                    skip(.mediaNotInProject)
                    continue
                }
                // TODO: (#8) still images can't go into an AVComposition; the
                // custom compositor will draw them over empty time instead.
                guard item.kind != .image else {
                    skip(.stillImage)
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
            if let picture, picture.compositionTrack != nil { pictures.append(picture) }
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
            CompositorInstruction(
                timeRange: CMTimeRange(start: start, end: end), layers: layers.compactMap { $0.placement(at: start) },
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

    // MARK: - Fitting pictures

    /// Where a picture goes in the frame: turned upright by its track's
    /// preferred transform, fitted into the render size and centred, then
    /// scaled, turned clockwise and moved by the clip's transform at a time
    /// from the clip's start. In the video composition's coordinates, which
    /// start at the top left.
    static func layerTransform(
        naturalSize: CGSize, preferredTransform: CGAffineTransform, clipTransform: ClipTransform,
        renderSize: CGSize, at localTime: CMTime
    ) -> CGAffineTransform {
        FrameComposer.fitTransform(naturalSize: naturalSize, preferredTransform: preferredTransform, renderSize: renderSize)
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
    /// timeline, after empty time from the clip before. False when none of
    /// the clip's source range is in the media.
    mutating func place(
        _ clip: Clip, from source: SourceTrack, in composition: AVMutableComposition, settings: ProjectSettings
    ) throws -> Bool {
        var sourceRange = clip.sourceRange.intersection(source.timeRange)
        guard sourceRange.duration > .zero else { return false }
        var start = clip.timelineStart + (sourceRange.start - clip.sourceRange.start)
        // Clips on a track shouldn't overlap; if one does, the earlier clip
        // wins and the later one loses its front.
        if start < cursor {
            let overlap = cursor - start
            guard overlap < sourceRange.duration else { return false }
            sourceRange = CMTimeRange(start: sourceRange.start + overlap, duration: sourceRange.duration - overlap)
            start = cursor
        }

        if compositionTrack == nil {
            let mediaType: AVMediaType = kind == .video ? .video : .audio
            compositionTrack = composition.addMutableTrack(withMediaType: mediaType, preferredTrackID: kCMPersistentTrackID_Invalid)
            if let compositionTrack, kind == .audio {
                audioParameters = AVMutableAudioMixInputParameters(track: compositionTrack)
            }
        }
        guard let compositionTrack else { return false }
        if start > cursor {
            compositionTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start))
        }
        try compositionTrack.insertTimeRange(sourceRange, of: source.track, at: start)
        let timelineRange = CMTimeRange(start: start, duration: sourceRange.duration)
        cursor = timelineRange.end
        let tail = CompositionBuilder.audioTail(for: clip)
        ringsUntil = kind == .audio && tail > .zero ? cursor + tail : .negativeInfinity
        lastPlaced = (source, sourceRange)
        segments.append(CompositionLayer.Segment(clipID: clip.id, mediaID: clip.mediaID, timelineRange: timelineRange, sourceRange: sourceRange))

        switch kind {
        case .video:
            placements.append(CompositorLayer(
                trackID: compositionTrack.trackID, clip: clip,
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

    private static func open(_ item: MediaItem, resolver: MediaResolver, usesProxies: Bool) async -> Result<LoadedMedia, LoadFailure> {
        guard let url = resolver.url(for: item), (try? url.checkResourceIsReachable()) == true else {
            return .failure(LoadFailure(reason: .fileNotFound))
        }
        // Precise timing, so cuts land on the frames the timeline shows.
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            var video = try await asset.loadTracks(withMediaType: .video).first
            // Phones add extra audio tracks, such as spatial audio, that are
            // turned off; the main one is the first that's on.
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            var audio = audioTracks.first
            for track in audioTracks where try await track.load(.isEnabled) {
                audio = track
                break
            }
            guard video != nil || audio != nil else { return .failure(LoadFailure(reason: .unreadable)) }
            var assets = [asset]
            // Mono sound plays from a stereo copy where there is one, so it
            // can be panned.
            if audio != nil, DerivedMedia.stereoAudio.applies(to: item),
               let stereo = await derivedTrack(.stereoAudio, of: item, mediaType: .audio, resolver: resolver) {
                assets.append(stereo.asset)
                audio = stereo.track
            }
            // Large video's picture plays from its proxy, if asked to and
            // there is one; its sound is still the original's.
            if usesProxies, video != nil, DerivedMedia.proxy.applies(to: item),
               let proxy = await derivedTrack(.proxy, of: item, mediaType: .video, resolver: resolver) {
                assets.append(proxy.asset)
                video = proxy.track
            }
            return .success(LoadedMedia(assets: assets, video: try await source(video), audio: try await source(audio)))
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
