@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@testable import MontageEngine
import Synchronization
import Testing

private let landscape = MediaItem(
    name: "IMG_3311.mp4", kind: .video, location: .package(path: "IMG_3311.mp4"),
    metadata: MediaMetadata(duration: CMTime(value: 11250, timescale: 1000), audioChannelCount: 2, audioSampleRate: 48000)
)

private let resolver = MediaResolver { item in
    guard case .package(let path) = item.location else { return nil }
    return Samples.url(path)
}

private func seconds(_ value: Double) -> CMTime {
    CMTime(seconds: value, preferredTimescale: 600)
}

/// A clip of the landscape sample's sound, from a second in.
private func soundClip(at start: Double = 0, duration: Double, effects: [Effect.Kind] = []) -> Clip {
    Clip(
        mediaID: landscape.id, sourceRange: CMTimeRange(start: seconds(1), duration: seconds(duration)),
        timelineStart: seconds(start), effects: effects.map { Effect($0) }
    )
}

/// A project with the clips on an audio track and, if `runsTo` is given, a
/// picture-only clip on a video track that keeps the composition going.
private func project(_ clips: [Clip], runsTo end: Double? = nil) -> Project {
    var tracks = [Track(kind: .audio, clips: clips)]
    if let end {
        tracks.insert(Track(kind: .video, clips: [Clip(
            mediaID: landscape.id, sourceRange: CMTimeRange(start: .zero, duration: seconds(end)), isAudioDetached: true
        )]), at: 0)
    }
    return Project(media: [landscape], tracks: tracks)
}

private func build(_ project: Project, snapshot: ProjectSnapshot? = nil) async throws -> BuiltComposition {
    let built = try await CompositionBuilder(project: project, mediaResolver: resolver, snapshot: snapshot).build()
    #expect(built.skippedClips.isEmpty)
    return built
}

/// Stereo sound, as float samples on each side.
struct RenderedAudio {
    static let sampleRate = 48_000.0
    var left: [Float] = []
    var right: [Float] = []

    var duration: Double { Double(left.count) / Self.sampleRate }

    /// How loud a side is over a stretch, in seconds, as root mean square.
    func rms(_ side: KeyPath<RenderedAudio, [Float]>, _ from: Double, _ to: Double) -> Double {
        let samples = self[keyPath: side]
        let start = min(Int(from * Self.sampleRate), samples.count)
        let end = min(Int(to * Self.sampleRate), samples.count)
        guard end > start else { return 0 }
        let sum = samples[start..<end].reduce(0.0) { $0 + Double($1) * Double($1) }
        return (sum / Double(end - start)).squareRoot()
    }

    /// Reads an asset's sound, through an audio mix if there is one, the way
    /// export does.
    static func read(_ asset: AVAsset, audioMix: AVAudioMix? = nil) async throws -> RenderedAudio {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = audioMix
        reader.add(output)
        #expect(reader.startReading())
        var audio = RenderedAudio()
        while let buffer = output.copyNextSampleBuffer() {
            guard let data = try buffer.dataBuffer?.dataBytes() else { continue }
            data.withUnsafeBytes { bytes in
                let samples = bytes.bindMemory(to: Float.self)
                for index in stride(from: 0, to: samples.count - 1, by: 2) {
                    audio.left.append(samples[index])
                    audio.right.append(samples[index + 1])
                }
            }
        }
        #expect(reader.status == .completed, "\(String(describing: reader.error))")
        return audio
    }

    static func read(_ built: BuiltComposition) async throws -> RenderedAudio {
        try await read(built.composition, audioMix: built.audioMix)
    }
}

@Suite(.enabled(if: Samples.isAvailable, "Needs the sample media"))
struct AudioEffectsTests {
    @Test func theSampleIsStereo() async throws {
        let dry = try await RenderedAudio.read(try await build(project([soundClip(duration: 2)])))
        #expect(abs(dry.duration - 2) < 0.05)
        #expect(dry.rms(\.left, 0, 2) > 0.005)
        #expect(dry.rms(\.right, 0, 2) > 0.005)
    }

    @Test func panningHardLeftSilencesTheRight() async throws {
        var pan = Pan()
        pan.position = Animatable(-1)
        let dry = try await RenderedAudio.read(try await build(project([soundClip(duration: 2)])))
        let panned = try await RenderedAudio.read(try await build(project([soundClip(duration: 2, effects: [.pan(pan)])])))

        #expect(panned.rms(\.right, 0, 2) < 1e-6)
        // Both sides end up on the left.
        #expect(panned.rms(\.left, 0, 2) > dry.rms(\.left, 0, 2))
    }

    @Test func aKeyframedPanMovesAcross() async throws {
        var pan = Pan()
        pan.position = Animatable(0, keyframes: [
            Keyframe(time: .zero, value: -1), Keyframe(time: seconds(2), value: 1),
        ])
        let dry = try await RenderedAudio.read(try await build(project([soundClip(duration: 3)])))
        let panned = try await RenderedAudio.read(try await build(project([soundClip(duration: 3, effects: [.pan(pan)])])))

        // Hard left at the start, centred (as it was) midway, hard right
        // from two seconds on.
        #expect(panned.rms(\.right, 0, 0.01) < 0.05 * panned.rms(\.left, 0, 0.01) + 1e-6)
        #expect(abs(panned.rms(\.left, 0.98, 1.02) - dry.rms(\.left, 0.98, 1.02)) < 0.1 * dry.rms(\.left, 0.98, 1.02))
        #expect(abs(panned.rms(\.right, 0.98, 1.02) - dry.rms(\.right, 0.98, 1.02)) < 0.1 * dry.rms(\.right, 0.98, 1.02))
        #expect(panned.rms(\.left, 2.1, 3) < 1e-6)
        #expect(panned.rms(\.right, 2.1, 3) > 0.005)
    }

    @Test func gainChangesTheLevel() async throws {
        var louder = Gain()
        louder.decibels = Animatable(6)
        var quieter = Gain()
        quieter.decibels = Animatable(-12)
        let dry = try await RenderedAudio.read(try await build(project([soundClip(duration: 2)])))
        let up = try await RenderedAudio.read(try await build(project([soundClip(duration: 2, effects: [.gain(louder)])])))
        let down = try await RenderedAudio.read(try await build(project([soundClip(duration: 2, effects: [.gain(quieter)])])))

        let level = dry.rms(\.left, 0.1, 1.9)
        #expect(abs(up.rms(\.left, 0.1, 1.9) / level - pow(10, 6.0 / 20)) < 0.01)
        #expect(abs(down.rms(\.left, 0.1, 1.9) / level - pow(10, -12.0 / 20)) < 0.01)
    }

    @Test func anEqualizerCutTakesEnergyOut() async throws {
        var equalizer = Equalizer()
        equalizer.bands = [100, 400, 1600, 6400].map { Equalizer.Band(frequency: $0, gain: -24, bandwidth: 2) }
        var flat = Equalizer()
        flat.bands = [100, 400, 1600, 6400].map { Equalizer.Band(frequency: $0) }
        let dry = try await RenderedAudio.read(try await build(project([soundClip(duration: 2)])))
        let cut = try await RenderedAudio.read(try await build(project([soundClip(duration: 2, effects: [.equalizer(equalizer)])])))
        let unchanged = try await RenderedAudio.read(try await build(project([soundClip(duration: 2, effects: [.equalizer(flat)])])))

        let level = dry.rms(\.left, 0.1, 1.9)
        #expect(cut.rms(\.left, 0.1, 1.9) < 0.3 * level)
        #expect(abs(unchanged.rms(\.left, 0.1, 1.9) - level) < 0.05 * level)
    }

    @Test func aReverbRingsOutPastTheClip() async throws {
        var reverb = Reverb()
        reverb.room = .cathedral
        reverb.mix = Animatable(0.5)
        let wet = try await build(project([soundClip(duration: 1.5, effects: [.reverb(reverb)])], runsTo: 4))
        let dry = try await build(project([soundClip(duration: 1.5)], runsTo: 4))

        // The track goes on under the tail, past the end of the timeline
        // until the cathedral has died away.
        let wetTrack = try #require(try await wet.composition.loadTracks(withMediaType: .audio).first)
        #expect(try await wetTrack.load(.timeRange).end == seconds(7.5))
        #expect(wet.duration == seconds(7.5))
        #expect(dry.duration == seconds(4))

        let wetAudio = try await RenderedAudio.read(wet)
        let dryAudio = try await RenderedAudio.read(dry)
        #expect(dryAudio.rms(\.left, 1.6, 2.4) < 1e-6)
        #expect(wetAudio.rms(\.left, 1.6, 2.4) > 0.05 * wetAudio.rms(\.left, 0.2, 1.4))
        // Fading away as it goes.
        #expect(wetAudio.rms(\.left, 3.2, 4) < wetAudio.rms(\.left, 1.6, 2.4))
    }

    @Test func aTailAfterTheLastClipRingsOutPastTheEnd() async throws {
        var delay = Delay()
        delay.mix = Animatable(0.5)
        let echoing = project([soundClip(duration: 1, effects: [.delay(delay)])])
        let built = try await build(echoing)
        // The timeline still ends with the clip; the composition runs on for
        // the echoes.
        #expect(echoing.duration == seconds(1))
        #expect(built.duration == seconds(2.5))
        #expect(built.composition.duration == seconds(2.5))
        let audio = try await RenderedAudio.read(built)
        #expect(audio.duration > 2.4)
        #expect(audio.rms(\.left, 1.05, 1.5) > 0.05 * audio.rms(\.left, 0.1, 0.9))

        // Without a tail, it ends with the clip.
        let plain = try await build(project([soundClip(duration: 1)]))
        #expect(plain.duration == seconds(1))
    }

    @Test func aTailUnderALongerClipLeavesTheLengthAlone() async throws {
        let echoing = soundClip(duration: 1, effects: [.delay(Delay())])
        let built = try await build(project([echoing], runsTo: 4))
        #expect(built.duration == seconds(4))
    }

    @Test func aDelayEchoesIntoTheGapAfterTheClip() async throws {
        var delay = Delay()
        delay.mix = Animatable(0.5)
        let built = try await build(project([soundClip(duration: 1, effects: [.delay(delay)])], runsTo: 3))
        let audio = try await RenderedAudio.read(built)
        #expect(audio.rms(\.left, 1.05, 1.5) > 0.05 * audio.rms(\.left, 0.1, 0.9))
    }

    @Test func aDelayEchoesIntoEmptyTimeBeforeTheNextClip() async throws {
        var delay = Delay()
        delay.mix = Animatable(0.5)
        let echoing = soundClip(duration: 1, effects: [.delay(delay)])
        let later = soundClip(at: 3, duration: 1)
        let built = try await build(project([echoing, later]))
        // Clear of the tail, the next clip shares the track, which has empty
        // time between the two for the echoes to ring into.
        #expect(built.audioLayers.count == 1)
        let audio = try await RenderedAudio.read(built)
        #expect(audio.rms(\.left, 1.05, 1.5) > 0.05 * audio.rms(\.left, 0.1, 0.9))
    }

    @Test func aClipInATailGoesOnATrackOfItsOwn() async throws {
        let echoing = soundClip(duration: 1.5, effects: [.delay(Delay())])
        let next = soundClip(at: 2, duration: 1)
        #expect(echoing.audioTail > seconds(0.5))
        let built = try await build(project([echoing, next]))

        // Nothing moved on the timeline; the second clip is on a second
        // composition track, clear of the first one's echoes.
        #expect(built.audioLayers.count == 2)
        #expect(built.audioLayers.map { $0.segments.map(\.clipID) } == [[echoing.id], [next.id]])
        #expect(built.audioLayers[1].segments.first?.timelineRange.start == seconds(2))
        #expect(built.duration == seconds(3))

        // Without a tail, they share one.
        let plain = try await build(project([soundClip(duration: 1.5), next]))
        #expect(plain.audioLayers.count == 1)
    }

    @Test func valuesAreReadFromTheSnapshotAsItPlays() async throws {
        var pan = Pan()
        pan.position = Animatable(0)
        let original = project([soundClip(duration: 1, effects: [.pan(pan)])])
        let snapshot = ProjectSnapshot(original)
        let built = try await build(original, snapshot: snapshot)

        // Turned hard left after the build: heard without building again.
        var edited = original
        let clip = edited.tracks[0].clips[0]
        pan.position = Animatable(-1)
        edited.tracks[0].update(clip.id) { $0.effects[0].kind = .pan(pan) }
        #expect(!PlaybackController.needsRebuild(from: original, to: edited))
        snapshot.update(edited)
        let panned = try await RenderedAudio.read(built)
        #expect(panned.rms(\.right, 0, 1) < 1e-6)

        // Turned off: the sound is as it was.
        edited.tracks[0].update(clip.id) { $0.effects[0].isEnabled = false }
        snapshot.update(edited)
        let off = try await RenderedAudio.read(built)
        #expect(off.rms(\.right, 0, 1) > 0.005)
    }

    @Test func changingTheShapeOfTheEffectsRebuilds() {
        let original = project([soundClip(duration: 1, effects: [.pan(Pan())])])
        let clip = original.tracks[0].clips[0]
        func edit(_ change: (inout Clip) -> Void) -> Project {
            var project = original
            project.tracks[0].update(clip.id, change)
            return project
        }
        // A new effect needs a unit to run it.
        #expect(PlaybackController.needsRebuild(from: original, to: edit { $0.effects.append(Effect(.reverb(Reverb()))) }))
        // A longer tail needs more room.
        let echoing = edit { $0.effects.append(Effect(.delay(Delay()))) }
        var longer = echoing
        longer.tracks[0].update(clip.id) {
            guard case .delay(var delay) = $0.effects[1].kind else { return }
            delay.time = Animatable(1)
            $0.effects[1].kind = .delay(delay)
        }
        #expect(PlaybackController.needsRebuild(from: echoing, to: longer))
        // A delay's mix is only a value.
        var wetter = echoing
        wetter.tracks[0].update(clip.id) {
            guard case .delay(var delay) = $0.effects[1].kind else { return }
            delay.mix = Animatable(0.9)
            $0.effects[1].kind = .delay(delay)
        }
        #expect(!PlaybackController.needsRebuild(from: echoing, to: wetter))
    }

    @Test func tailsFollowTheEffects() {
        var delay = Delay()
        delay.time = Animatable(0.5)
        delay.feedback = Animatable(0.5)
        // 0.5 to the tenth is under a thousandth: ten echoes.
        #expect(abs(Effect.Kind.delay(delay).tailDuration - 5) < 1e-9)
        delay.feedback = Animatable(0)
        #expect(Effect.Kind.delay(delay).tailDuration == 0.5)
        #expect(Effect.Kind.reverb(Reverb()).tailDuration > 0)
        #expect(Effect.Kind.pan(Pan()).tailDuration == 0)

        var clip = soundClip(duration: 1, effects: [.delay(delay)])
        #expect(clip.audioTail == seconds(0.5))
        clip.effects[0].isEnabled = false
        #expect(clip.audioTail == .zero)
    }

    @Test func clipsAreMeteredAsTheyAreRead() async throws {
        let clip = soundClip(duration: 1)
        let built = try await build(project([clip]))
        #expect(built.audioLevels.isMetering(clip.id))
        _ = try await RenderedAudio.read(built)
        let peak = try #require(built.audioLevels.takePeak(of: clip.id))
        #expect(peak.left > 0.01 && peak.right > 0.01)
        // Taken, it starts again.
        #expect(built.audioLevels.takePeak(of: clip.id)?.left == 0)
    }

    @MainActor
    @Test func theTapsRunInThePlayer() async throws {
        var pan = Pan()
        pan.position = Animatable(-1)
        let clip = soundClip(duration: 3, effects: [.pan(pan)])
        let built = try await build(project([clip]))
        let player = AVPlayer(playerItem: built.makePlayerItem())
        player.isMuted = true
        player.play()
        defer { player.pause() }
        var peak: (left: Float, right: Float) = (0, 0)
        for _ in 0..<40 where peak.left == 0 {
            try await Task.sleep(for: .milliseconds(50))
            peak = built.audioLevels.takePeak(of: clip.id) ?? (0, 0)
        }
        #expect(peak.left > 0.01)
        #expect(peak.right < 1e-6)
    }

    // MARK: - Export

    private func pannedLeft() async throws -> BuiltComposition {
        var pan = Pan()
        pan.position = Animatable(-1)
        return try await build(project([soundClip(duration: 2, effects: [.pan(pan)])], runsTo: 2))
    }

    private func temporaryURL(_ ext: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MontageAudioEffectsTests", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "\(UUID().uuidString).\(ext)")
    }

    @Test func mp4ExportCarriesTheEffects() async throws {
        let url = try temporaryURL("mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        try await Exporter().export(RenderSource(try await pannedLeft()), settings: ExportSettings(resolution: .hd720, quality: .low), to: url)

        let audio = try await RenderedAudio.read(AVURLAsset(url: url))
        #expect(audio.duration > 1.9)
        #expect(audio.rms(\.left, 0.1, 1.9) > 0.005)
        #expect(audio.rms(\.right, 0.1, 1.9) < 0.01 * audio.rms(\.left, 0.1, 1.9))
    }

    @Test func aviExportCarriesTheEffects() async throws {
        let sink = PCMSink()
        let url = try temporaryURL("avi")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = ExportSettings(format: .avi, codec: .motionJPEG, resolution: .hd720, frameRate: .fps(30), quality: .low)
        try await Exporter { _, _ in sink }.export(RenderSource(try await pannedLeft()), settings: settings, to: url)

        // 16-bit stereo, left then right.
        let samples = sink.pcm.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        #expect(samples.count > 2 * 90_000)
        let left = stride(from: 0, to: samples.count, by: 2).map { Double(samples[$0]) }
        let right = stride(from: 1, to: samples.count, by: 2).map { Double(samples[$0]) }
        func rms(_ values: [Double]) -> Double { (values.reduce(0) { $0 + $1 * $1 } / Double(values.count)).squareRoot() }
        #expect(rms(left) > 100)
        #expect(rms(right) < 1)
    }
}

/// Keeps the PCM the AVI pipeline hands a container writer.
private final class PCMSink: EncodedFrameSink, @unchecked Sendable {
    private let data = Mutex(Data())
    var pcm: Data { data.withLock { $0 } }

    func appendVideo(_ sampleBuffer: CMSampleBuffer, isKeyframe: Bool) throws {}
    func appendAudio(_ pcm: Data) throws { data.withLock { $0.append(pcm) } }
    func finish() throws {}
    func cancel() {}
}

/// Runs an `AudioEffectsProcessor` directly over made-up stereo buffers.
@Suite struct AudioEffectsProcessorTests {
    @Test func anEffectTurnedBackOnDoesNotReplayWhatItHeldBefore() throws {
        var delay = Delay()
        delay.mix = Animatable(1)
        delay.feedback = Animatable(0)
        delay.time = Animatable(0.1)
        let clip = Clip(
            mediaID: MediaItem.ID(), sourceRange: CMTimeRange(start: .zero, duration: CMTime(seconds: 10, preferredTimescale: 600)),
            timelineStart: .zero, effects: [Effect(.delay(delay))]
        )
        let track = Track(kind: .audio, clips: [clip])
        var project = Project(tracks: [track])
        let snapshot = ProjectSnapshot(project)
        let processor = AudioEffectsProcessor(snapshot: snapshot, trackID: track.id, sections: [AudioEffectsProcessor.Section(
            clipID: clip.id, clipStart: 0, start: 0, end: 10, tailEnd: 10, layout: clip.audioEffectLayout, meter: AudioMeter()
        )])
        let sampleRate = 48_000.0
        let frames = 512
        let format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        processor.prepare(format: format, maxFrames: frames)
        defer { processor.unprepare() }

        let buffers = AudioBufferList.allocate(maximumBuffers: 2)
        let storage = (0..<2).map { _ in UnsafeMutablePointer<Float>.allocate(capacity: frames) }
        defer {
            storage.forEach { $0.deallocate() }
            free(buffers.unsafeMutablePointer)
        }
        var position = 0
        /// Processes one buffer of a constant level, and gives back its peak.
        func process(_ level: Float) -> Float {
            for index in 0..<2 {
                storage[index].update(repeating: level, count: frames)
                buffers[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: storage[index])
            }
            let range = CMTimeRange(
                start: CMTime(value: CMTimeValue(position), timescale: 48_000), duration: CMTime(value: CMTimeValue(frames), timescale: 48_000)
            )
            processor.process(buffers, frameCount: frames, timeRange: range, isDiscontinuity: position == 0)
            position += frames
            return (0..<frames).map { abs(storage[0][$0]) }.max() ?? 0
        }
        func setEnabled(_ isEnabled: Bool) {
            project.tracks[0].update(clip.id) { $0.effects[0].isEnabled = isEnabled }
            snapshot.update(project)
        }

        // Sound goes into the delay, and it's turned off before it echoes.
        for _ in 0..<4 { _ = process(0.5) }
        setEnabled(false)
        for _ in 0..<20 { _ = process(0) }
        // Turned back on over silence, it has nothing to echo.
        setEnabled(true)
        var peak: Float = 0
        for _ in 0..<20 { peak = max(peak, process(0)) }
        #expect(peak < 1e-6)
    }
}
