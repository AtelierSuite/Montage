import AVFoundation
import CoreGraphics
import CoreMedia

/// Turns a project into the AVFoundation objects that play and export it:
///
/// ```
/// Project ─► CompositionBuilder ─► AVComposition       (what plays when)
///                                  AVVideoComposition  (where each picture goes)
///                                  AVAudioMix          (how loud each clip is)
/// ```
///
/// Each video track of the timeline that isn't hidden becomes a composition
/// video track, a layer, and every track that isn't muted an audio track: a
/// video clip's own sound goes on its track's audio track unless it has been
/// detached, and an audio track's clips go on its own. Clips are cut out of
/// their media with `insertTimeRange`, and gaps between them are empty time,
/// which draws black and plays silence.
///
/// The video composition fits each clip's picture, turned upright, into the
/// render size, then moves it by the clip's transform and fades it by its
/// opacity. AVFoundation's built-in compositor can only move a layer by one
/// transform per clip and fade it in straight ramps, so the transform is
/// taken at the clip's start and keyframed opacity and volume are followed
/// with ramps. The custom compositor (#8) will evaluate every parameter per
/// frame instead, finding its clips through `BuiltComposition.videoLayers`.
/// It will also fix a fault of the built-in one: a faded layer with nothing
/// under it blends with a dark green rather than with black.
public struct CompositionBuilder: Sendable {
    public var project: Project
    public var mediaResolver: MediaResolver

    public init(project: Project, mediaResolver: MediaResolver) {
        self.project = project
        self.mediaResolver = mediaResolver
    }

    /// How long a clip's sound keeps going after the clip ends, such as a
    /// reverb or delay ringing out, so the composition can leave room for it.
    ///
    /// TODO: (#5, with the audio taps) work this out from the clip's enabled
    /// effects whose `hasTail` is set, and have `LayerWriter.place` keep that
    /// much empty time after the clip, before the next one on its audio track
    /// (moving a clip that would cut the tail off onto a track of its own).
    /// Until the taps exist nothing rings out, so there's no tail. A tail
    /// after the very last clip needs more: a composition can't end in empty
    /// time, so the taps will have to keep the track going themselves.
    public static func audioTail(for clip: Clip) -> CMTime {
        .zero
    }

    /// Builds the composition. Clips whose media can't be found or used are
    /// left out as empty time and listed in `skippedClips`; only cancelling
    /// the task throws. Runs off the caller's actor, so the main actor can
    /// call it without waiting on the media being opened.
    @concurrent
    public func build() async throws -> BuiltComposition {
        let composition = AVMutableComposition()
        var media = MediaLoader(resolver: mediaResolver)
        var skipped: [SkippedClip] = []
        var pictures: [LayerWriter] = []
        var sounds: [LayerWriter] = []

        for track in project.tracks {
            let wantsPicture = track.kind == .video && !track.isHidden
            let wantsSound = !track.isMuted
            guard wantsPicture || wantsSound else { continue }
            var picture = wantsPicture ? LayerWriter(kind: .video, trackID: track.id) : nil
            var sound = wantsSound ? LayerWriter(kind: .audio, trackID: track.id) : nil

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
                            guard try picture!.place(clip, from: video, in: composition, settings: project.settings) else {
                                skip(.outsideMedia)
                                continue
                            }
                        }
                        if !clip.isAudioDetached, let audio = source.audio {
                            _ = try sound?.place(clip, from: audio, in: composition, settings: project.settings)
                        }
                    case .audio:
                        guard let audio = source.audio else {
                            skip(.noUsableTrack)
                            continue
                        }
                        if try sound?.place(clip, from: audio, in: composition, settings: project.settings) == false {
                            skip(.outsideMedia)
                        }
                    }
                } catch {
                    skip(.unreadable)
                }
            }
            if let picture, picture.compositionTrack != nil { pictures.append(picture) }
            if let sound, sound.compositionTrack != nil { sounds.append(sound) }
        }

        let writers = pictures + sounds
        guard !writers.isEmpty else {
            return BuiltComposition(
                project: project, composition: AVComposition(), videoComposition: nil, audioMix: nil,
                duration: .zero, videoLayers: [], audioLayers: [], skippedClips: skipped
            )
        }
        // A composition can't end in empty time, so it runs to the end of
        // the last clip placed: clips left out at the end shorten it.
        let end = writers.map(\.cursor).max() ?? .zero

        return BuiltComposition(
            project: project,
            composition: composition.copy() as! AVComposition,
            videoComposition: pictures.isEmpty ? nil : videoComposition(for: pictures, duration: end),
            audioMix: sounds.isEmpty ? nil : audioMix(for: sounds),
            duration: end,
            videoLayers: pictures.map(\.layer),
            audioLayers: sounds.map(\.layer),
            skippedClips: skipped
        )
    }

    /// One instruction for each stretch of the timeline between the points
    /// where a clip starts or ends, holding the layers showing through it,
    /// top layer first, over black.
    private func videoComposition(for layers: [LayerWriter], duration: CMTime) -> AVVideoComposition {
        var cuts = Set([CMTime.zero, duration])
        for layer in layers {
            for segment in layer.layer.segments {
                cuts.insert(segment.timelineRange.start)
                cuts.insert(segment.timelineRange.end)
            }
        }
        let times = cuts.filter { $0 <= duration }.sorted()
        // One layer instruction per layer, holding every one of its clips'
        // settings at their times, used in each instruction it shows in.
        let layerInstructions = layers.map { AVVideoCompositionLayerInstruction(configuration: $0.layerConfiguration) }
        let black = CGColor(gray: 0, alpha: 1)
        let instructions = zip(times, times.dropFirst()).map { start, end in
            let showing = layers.indices.reversed().filter { layers[$0].layer.segment(at: start) != nil }
            return AVVideoCompositionInstruction(configuration: AVVideoCompositionInstruction.Configuration(
                backgroundColor: black,
                layerInstructions: showing.map { layerInstructions[$0] },
                timeRange: CMTimeRange(start: start, end: end)
            ))
        }
        // TODO: (#8) set `customVideoCompositorClass` to the custom compositor,
        // with instructions that carry the layers' clips.
        return AVVideoComposition(configuration: AVVideoComposition.Configuration(
            frameDuration: project.settings.frameDuration,
            instructions: instructions,
            renderSize: project.settings.renderSize
        ))
    }

    private func audioMix(for layers: [LayerWriter]) -> AVAudioMix {
        let mix = AVMutableAudioMix()
        mix.inputParameters = layers.compactMap(\.audioParameters).map { $0.copy() as! AVAudioMixInputParameters }
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
        let upright = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
        guard upright.width > 0, upright.height > 0 else { return preferredTransform }
        // About its own centre, so scaling and turning keep it in place.
        var transform = preferredTransform
            .concatenating(CGAffineTransform(translationX: -upright.midX, y: -upright.midY))
        let fit = min(renderSize.width / upright.width, renderSize.height / upright.height)
        let scale = fit * clipTransform.scale.value(at: localTime)
        transform = transform.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        // Positive angles turn clockwise when y runs down.
        transform = transform.concatenating(CGAffineTransform(rotationAngle: clipTransform.rotation.value(at: localTime) * .pi / 180))
        let position = clipTransform.position.value(at: localTime)
        return transform.concatenating(CGAffineTransform(translationX: position.x * renderSize.width, y: position.y * renderSize.height))
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
    private(set) var layerConfiguration = AVVideoCompositionLayerInstruction.Configuration()
    private(set) var audioParameters: AVMutableAudioMixInputParameters?

    init(kind: CompositionLayer.Kind, trackID: Track.ID) {
        self.kind = kind
        self.trackID = trackID
    }

    var layer: CompositionLayer {
        CompositionLayer(kind: kind, trackID: trackID, compositionTrackID: compositionTrack?.trackID ?? kCMPersistentTrackID_Invalid, segments: segments)
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
            if let compositionTrack {
                layerConfiguration = AVVideoCompositionLayerInstruction.Configuration(trackID: compositionTrack.trackID)
                if kind == .audio { audioParameters = AVMutableAudioMixInputParameters(track: compositionTrack) }
            }
        }
        guard let compositionTrack else { return false }
        if start > cursor {
            compositionTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, end: start))
        }
        try compositionTrack.insertTimeRange(sourceRange, of: source.track, at: start)
        let timelineRange = CMTimeRange(start: start, duration: sourceRange.duration)
        cursor = timelineRange.end
        segments.append(CompositionLayer.Segment(clipID: clip.id, mediaID: clip.mediaID, timelineRange: timelineRange, sourceRange: sourceRange))

        switch kind {
        case .video:
            layerConfiguration.setTransform(CompositionBuilder.layerTransform(
                naturalSize: source.naturalSize, preferredTransform: source.preferredTransform,
                clipTransform: clip.transform, renderSize: settings.renderSize, at: clip.localTime(start)
            ), at: start)
            let ramps = clip.opacity.ramps(over: timelineRange, clipStart: clip.timelineStart)
            if ramps.isEmpty {
                layerConfiguration.setOpacity(Float(clip.opacity.value(at: clip.localTime(start))), at: start)
            }
            for ramp in ramps {
                layerConfiguration.addOpacityRamp(AVVideoCompositionLayerInstruction.OpacityRamp(
                    timeRange: ramp.timeRange, start: Float(ramp.start), end: Float(ramp.end)
                ))
            }
        case .audio:
            // Where the clip's audio tail would be left room for; nothing
            // rings out yet.
            _ = CompositionBuilder.audioTail(for: clip)
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
    /// Kept for as long as its tracks are used: a track only holds on to its
    /// asset weakly, and can't be inserted once the asset is gone.
    let asset: AVURLAsset
    let video: SourceTrack?
    let audio: SourceTrack?
}

private struct LoadFailure: Error {
    let reason: SkippedClip.Reason
}

/// Opens each media item's file once per build, however many clips use it.
private struct MediaLoader {
    let resolver: MediaResolver
    private var loaded: [MediaItem.ID: Result<LoadedMedia, LoadFailure>] = [:]

    init(resolver: MediaResolver) {
        self.resolver = resolver
    }

    mutating func load(_ item: MediaItem) async -> Result<LoadedMedia, LoadFailure> {
        if let result = loaded[item.id] { return result }
        let result = await Self.open(item, resolver: resolver)
        loaded[item.id] = result
        return result
    }

    private static func open(_ item: MediaItem, resolver: MediaResolver) async -> Result<LoadedMedia, LoadFailure> {
        guard let url = resolver.url(for: item), (try? url.checkResourceIsReachable()) == true else {
            return .failure(LoadFailure(reason: .fileNotFound))
        }
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
            return .success(LoadedMedia(asset: asset, video: try await source(video), audio: try await source(audio)))
        } catch {
            return .failure(LoadFailure(reason: .unreadable))
        }
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
