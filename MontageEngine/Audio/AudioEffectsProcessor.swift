import AudioToolbox
import AVFoundation

/// Runs the audio effects of the clips on one composition track, in its tap,
/// and meters each clip's sound.
///
/// The composition is built around the clips' effects as they were then
/// (which there are, in what order: their `AudioEffectLayout`), and the units
/// that run them are made when the tap is prepared, one set per clip. Their
/// values are read from the project snapshot once per buffer, at the
/// buffer's time, so turning an effect off or changing a value, keyframes
/// included, is heard on the next buffer without a rebuild.
///
/// Each clip's stretch runs on past its end for as long as its effects' tail
/// (see `CompositionBuilder`), with the clip's own sound silenced there, so a
/// reverb or delay rings out into whatever the track has after it: empty
/// time, or filler that keeps the track going.
///
/// Gain and pan are worked out here, ramped across each buffer so a moving
/// value doesn't click; the rest are Apple's Audio Units (see
/// `AudioUnitHost`). Pan needs two channels, so a tap on mono media's own
/// track leaves it as it is; the composition plays a stereo copy of mono
/// media instead where there is one (see `DerivedMedia.stereoAudio`), which
/// pan places as the one sound it is.
///
/// Everything here is touched only by the tap's callbacks, which never run at
/// the same time, hence the unchecked `Sendable`.
final class AudioEffectsProcessor: AudioTapProcessor, @unchecked Sendable {
    /// A clip on the track, and the effects that run over its sound.
    final class Section {
        let clipID: Clip.ID
        /// Where the clip starts on the timeline, which its keyframes are
        /// timed from, in seconds.
        let clipStart: Double
        /// Where its sound plays on the track, in seconds.
        let start: Double
        let end: Double
        /// Where its effects stop being run: after its tail.
        let tailEnd: Double
        fileprivate let slots: [Slot]
        /// Where the peaks of its sound, after the effects, are noted.
        let meter: AudioMeter
        /// Whether its media is mono, so two channels are the same sound,
        /// to be panned as one rather than as a stereo picture.
        let isMono: Bool

        init(
            clipID: Clip.ID, clipStart: Double, start: Double, end: Double, tailEnd: Double, layout: AudioEffectLayout,
            meter: AudioMeter, isMono: Bool = false
        ) {
            self.isMono = isMono
            self.clipID = clipID
            self.clipStart = clipStart
            self.start = start
            self.end = end
            self.tailEnd = tailEnd
            slots = layout.units.map(Slot.init)
            self.meter = meter
        }
    }

    /// One of a clip's effects, with what running it needs.
    fileprivate final class Slot {
        let effectID: Effect.ID
        let kind: AudioEffectLayout.Kind
        /// The Audio Unit that runs it, made when the tap is prepared. Nil
        /// for gain and pan, and when the unit couldn't be made.
        var unit: AudioUnitHost?
        var isEnabled = false
        /// Gain's factor or pan's position, as of the last buffer and as
        /// wanted for this one; nil until the first.
        var current: Float?
        var target: Float = 0
        /// The room the reverb unit is set up for.
        var room: Reverb.Room?

        init(_ unit: AudioEffectLayout.Unit) {
            effectID = unit.effectID
            kind = unit.kind
        }
    }

    let snapshot: ProjectSnapshot
    let trackID: Track.ID
    let sections: [Section]

    private var sampleRate = 0.0
    private var channels = 0
    /// Whether the audio comes in a format this can work on: 32-bit float,
    /// one buffer per channel, which is what taps are handed.
    private var isPrepared = false
    /// Part of the buffers being processed, for running a clip's effects over
    /// just its own frames.
    private var piece: UnsafeMutableAudioBufferListPointer?

    init(snapshot: ProjectSnapshot, trackID: Track.ID, sections: [Section]) {
        self.snapshot = snapshot
        self.trackID = trackID
        self.sections = sections
    }

    deinit {
        unprepare()
    }

    /// A tap that runs the effects of a layer's clips and meters them, adding
    /// a meter for each clip to `meters`. `end` is where the composition
    /// ends, which no tail runs past.
    static func tap(
        for layer: CompositionLayer, in project: Project, snapshot: ProjectSnapshot, end: CMTime,
        meters: inout [Clip.ID: AudioMeter]
    ) -> MTAudioProcessingTap? {
        guard let track = project.trackIndex(id: layer.trackID).map({ project.tracks[$0] }) else { return nil }
        var sections: [Section] = []
        for (index, segment) in layer.segments.enumerated() {
            guard let clip = track.clip(id: segment.clipID) else { continue }
            let meter = AudioMeter()
            meters[clip.id] = meter
            let next = index + 1 < layer.segments.count ? layer.segments[index + 1].timelineRange.start : end
            let tailEnd = max(min(segment.timelineRange.end + clip.audioTail, next, end), segment.timelineRange.end)
            sections.append(Section(
                clipID: clip.id, clipStart: clip.timelineStart.seconds,
                start: segment.timelineRange.start.seconds, end: segment.timelineRange.end.seconds, tailEnd: tailEnd.seconds,
                layout: clip.audioEffectLayout, meter: meter,
                isMono: project.mediaItem(id: clip.mediaID)?.metadata.audioChannelCount == 1
            ))
        }
        guard !sections.isEmpty else { return nil }
        return AudioTap.make(AudioEffectsProcessor(snapshot: snapshot, trackID: layer.trackID, sections: sections))
    }

    // MARK: - Tap

    func prepare(format: AudioStreamBasicDescription, maxFrames: Int) {
        unprepare()
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        guard format.mFormatID == kAudioFormatLinearPCM, isFloat, isNonInterleaved, format.mBitsPerChannel == 32,
              format.mChannelsPerFrame > 0 else { return }
        sampleRate = format.mSampleRate
        channels = Int(format.mChannelsPerFrame)
        piece = AudioBufferList.allocate(maximumBuffers: channels)
        for section in sections {
            for slot in section.slots {
                slot.unit = Self.makeUnit(for: slot.kind, format: format, maxFrames: maxFrames)
                slot.current = nil
                slot.room = nil
            }
        }
        isPrepared = true
    }

    func unprepare() {
        isPrepared = false
        for section in sections {
            for slot in section.slots { slot.unit = nil }
        }
        if let piece { free(piece.unsafeMutablePointer) }
        piece = nil
    }

    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, timeRange: CMTimeRange, isDiscontinuity: Bool) {
        guard isPrepared, let piece, buffers.count == channels, timeRange.start.isNumeric else { return }
        if isDiscontinuity {
            for section in sections {
                for slot in section.slots {
                    slot.unit?.reset()
                    slot.current = nil
                }
            }
        }
        let start = timeRange.start.seconds
        let end = start + Double(frameCount) / sampleRate
        func frame(at time: Double) -> Int {
            min(max(Int(((time - start) * sampleRate).rounded()), 0), frameCount)
        }

        for section in sections where section.start < end && section.tailEnd > start {
            let first = frame(at: section.start)
            let last = frame(at: section.tailEnd)
            guard last > first else { continue }
            // Past the clip's end is its tail, where the track has empty
            // time or filler: the effects ring on over silence.
            let silentFrom = min(max(frame(at: section.end), first), last)
            if silentFrom < last {
                for buffer in buffers {
                    let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
                    (samples + silentFrom).update(repeating: 0, count: last - silentFrom)
                }
            }

            update(section, at: max(start, section.start) - section.clipStart)
            for index in 0..<channels {
                piece[index] = AudioBuffer(
                    mNumberChannels: 1, mDataByteSize: UInt32((last - first) * MemoryLayout<Float>.size),
                    mData: buffers[index].mData!.assumingMemoryBound(to: Float.self) + first
                )
            }
            run(section, over: piece, frameCount: last - first)
            meter(section, piece, frameCount: last - first)
        }
    }

    /// Notes the loudest sample on each side; a mono track's one channel
    /// is both.
    private func meter(_ section: Section, _ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        func peak(_ channel: Int) -> Float {
            let samples = buffers[channel].mData!.assumingMemoryBound(to: Float.self)
            var peak: Float = 0
            for index in 0..<frameCount { peak = max(peak, abs(samples[index])) }
            return peak
        }
        let left = peak(0)
        section.meter.note(left: left, right: buffers.count > 1 ? peak(1) : left)
    }

    // MARK: - Effects

    private static func makeUnit(for kind: AudioEffectLayout.Kind, format: AudioStreamBasicDescription, maxFrames: Int) -> AudioUnitHost? {
        switch kind {
        case .gain, .pan:
            return nil
        case .delay:
            return AudioUnitHost(subtype: kAudioUnitSubType_Delay, format: format, maxFrames: maxFrames)
        case .reverb:
            return AudioUnitHost(subtype: kAudioUnitSubType_Reverb2, format: format, maxFrames: maxFrames)
        case .equalizer(let bands):
            guard bands > 0 else { return nil }
            return AudioUnitHost(subtype: kAudioUnitSubType_NBandEQ, format: format, maxFrames: maxFrames) { unit in
                var count = UInt32(bands)
                AudioUnitSetProperty(
                    unit, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &count, UInt32(MemoryLayout<UInt32>.size)
                )
            }
        }
    }

    /// Reads the clip's effects at a time from its start into the slots.
    /// If an edit is being put in just then, the slots keep the values they
    /// had for the last buffer.
    private func update(_ section: Section, at seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 48000)
        let nyquist = sampleRate / 2
        _ = snapshot.readIfAvailable { project -> Bool in
            guard let trackIndex = project.trackIndex(id: trackID),
                  let clip = project.tracks[trackIndex].clip(id: section.clipID) else {
                for slot in section.slots { slot.isEnabled = false }
                return false
            }
            for slot in section.slots {
                guard let effect = clip.effects.first(where: { $0.id == slot.effectID }) else {
                    slot.isEnabled = false
                    continue
                }
                // A unit left off kept what it held then; turned back on,
                // it mustn't play that out over audio from another time.
                if effect.isEnabled, !slot.isEnabled { slot.unit?.reset() }
                slot.isEnabled = effect.isEnabled
                switch effect.kind {
                case .gain(let gain):
                    slot.target = gain.factor(at: time)
                case .pan(let pan):
                    slot.target = Float(min(max(pan.position.value(at: time), -1), 1))
                case .equalizer(let equalizer):
                    if let unit = slot.unit { equalizer.apply(to: unit, at: time, nyquist: nyquist) }
                case .delay(let delay):
                    if let unit = slot.unit { delay.apply(to: unit, at: time) }
                case .reverb(let reverb):
                    guard let unit = slot.unit else { continue }
                    if slot.room != reverb.room {
                        reverb.room.apply(to: unit)
                        slot.room = reverb.room
                    }
                    reverb.apply(to: unit, at: time)
                case .colorCorrection, .mosaic, .unsupported:
                    slot.isEnabled = false
                }
            }
            return true
        }
    }

    private func run(_ section: Section, over buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        // Mono media's sound stays the same on both sides through gain and
        // the equalizer, which treat both alike, but not once it's panned,
        // or through a delay or reverb, which make a stereo sound of it.
        var isMono = section.isMono
        for slot in section.slots where slot.isEnabled {
            switch slot.kind {
            case .gain:
                applyGain(slot, to: buffers, frameCount: frameCount)
            case .pan:
                applyPan(slot, to: buffers, frameCount: frameCount, isMono: isMono)
                isMono = false
            case .equalizer:
                slot.unit?.render(buffers, frameCount: frameCount)
            case .delay, .reverb:
                slot.unit?.render(buffers, frameCount: frameCount)
                isMono = false
            }
        }
    }

    /// Multiplies every channel by the gain, moving from the last buffer's
    /// to this one's across the buffer.
    private func applyGain(_ slot: Slot, to buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let from = slot.current ?? slot.target
        let to = slot.target
        slot.current = to
        let step = (to - from) / Float(frameCount)
        for buffer in buffers {
            let samples = buffer.mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<frameCount {
                samples[index] *= from + step * Float(index)
            }
        }
    }

    /// Moves the stereo picture left or right. Each channel is placed at a
    /// position with equal-power panning: centred, left stays left and right
    /// stays right; turned towards one side, the other side's channel moves
    /// across until, fully over, both play from that side.
    ///
    /// Mono media's sound, the same on both sides, is placed as one sound
    /// instead, as loud wherever it goes: centred it's as it was, and fully
    /// over it plays from that side alone, louder by the half it no longer
    /// sends to the other.
    private func applyPan(_ slot: Slot, to buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, isMono: Bool) {
        guard buffers.count == 2 else { return }
        let from = slot.current ?? slot.target
        let to = slot.target
        slot.current = to
        let left = buffers[0].mData!.assumingMemoryBound(to: Float.self)
        let right = buffers[1].mData!.assumingMemoryBound(to: Float.self)
        let step = (to - from) / Float(frameCount)
        if isMono {
            for index in 0..<frameCount {
                let (toLeft, toRight) = Self.equalPower(from + step * Float(index))
                let sound = (left[index] + right[index]) / 2
                left[index] = sound * toLeft * Float(2).squareRoot()
                right[index] = sound * toRight * Float(2).squareRoot()
            }
            return
        }
        for index in 0..<frameCount {
            let pan = from + step * Float(index)
            let leftPosition = pan > 0 ? 2 * pan - 1 : -1
            let rightPosition = pan < 0 ? 2 * pan + 1 : 1
            let (leftToLeft, leftToRight) = Self.equalPower(leftPosition)
            let (rightToLeft, rightToRight) = Self.equalPower(rightPosition)
            let l = left[index], r = right[index]
            left[index] = l * leftToLeft + r * rightToLeft
            right[index] = l * leftToRight + r * rightToRight
        }
    }

    /// How much of a sound at a position, from -1 (left) to 1 (right), goes
    /// to each side.
    private static func equalPower(_ position: Float) -> (left: Float, right: Float) {
        let angle = (position + 1) * .pi / 4
        return (cos(angle), sin(angle))
    }
}
