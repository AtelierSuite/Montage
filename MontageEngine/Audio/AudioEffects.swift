import AudioToolbox
import CoreMedia

// How each audio effect's parameters reach the sound: gain and pan are worked
// out in the tap itself, the rest are Apple's Audio Units with these settings.

extension Effect.Kind {
    /// How long the effect keeps sounding after its input stops, at the
    /// longest its parameters go: the time a reverb's room takes to die away,
    /// or a delay's echoes take to fall below hearing (60 dB down). Zero for
    /// effects without a tail.
    var tailDuration: Double {
        switch self {
        case .delay(let delay):
            let time = min(delay.time.extremes.upperBound, Delay.maximumTime)
            let feedback = min(max(delay.feedback.extremes.upperBound, 0), Delay.maximumFeedback)
            // Each echo is `feedback` times the one before.
            let echoes = feedback > 0 ? (log(0.001) / log(feedback)).rounded(.up) : 1
            return min(time * echoes, Delay.maximumTail)
        case .reverb(let reverb):
            return reverb.room.decay
        default:
            return 0
        }
    }
}

private extension Animatable<Double> {
    /// The lowest and highest the parameter goes.
    var extremes: ClosedRange<Double> {
        let values = [value] + keyframes.map(\.value)
        return values.min()!...values.max()!
    }
}

extension Clip {
    /// How long the clip's sound keeps going after it ends, through its
    /// enabled effects one after another.
    public var audioTail: CMTime {
        let seconds = effects.filter { $0.isEnabled }.map(\.kind.tailDuration).reduce(0, +)
        guard seconds > 0 else { return .zero }
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }

    /// Whether any of the clip's effects changes its sound, so its audio
    /// goes through a tap.
    var hasAudioEffects: Bool {
        effects.contains { $0.kind.runsInAudioTap }
    }

    /// What the composition is built around of the clip's audio effects: which
    /// there are and in what order, how they're set up, and how long they ring
    /// on. Anything else, such as a level or a keyframe that doesn't change
    /// the tail, the taps read while playing.
    public var audioEffectLayout: AudioEffectLayout {
        AudioEffectLayout(
            units: effects.filter(\.kind.runsInAudioTap).map { AudioEffectLayout.Unit(effectID: $0.id, kind: AudioEffectLayout.Kind($0.kind)) },
            tail: audioTail
        )
    }
}

/// The shape of a clip's audio effects, as far as building the composition
/// goes. Two clips with the same layout build the same taps.
extension Effect.Kind {
    /// Whether the effect changes the sound in an audio tap. An unsupported
    /// effect from another app is only kept, so it has no part in playback.
    var runsInAudioTap: Bool {
        switch self {
        case .gain, .pan, .equalizer, .delay, .reverb: true
        case .colorCorrection, .mosaic, .unsupported: false
        }
    }
}

public struct AudioEffectLayout: Equatable, Sendable {
    public struct Unit: Equatable, Sendable {
        public var effectID: Effect.ID
        public var kind: Kind
    }

    public enum Kind: Equatable, Sendable {
        case gain, pan, delay, reverb
        case equalizer(bands: Int)

        init(_ kind: Effect.Kind) {
            switch kind {
            case .gain: self = .gain
            case .pan: self = .pan
            case .equalizer(let equalizer): self = .equalizer(bands: equalizer.bands.count)
            case .delay: self = .delay
            case .reverb: self = .reverb
            // Only effects that run in a tap get this far.
            case .colorCorrection, .mosaic, .unsupported: self = .gain
            }
        }
    }

    public var units: [Unit]
    public var tail: CMTime
}

extension Project {
    /// Every clip's audio effect layout, so a change to one can be noticed.
    public var audioEffectLayouts: [Clip.ID: AudioEffectLayout] {
        var layouts: [Clip.ID: AudioEffectLayout] = [:]
        for track in tracks {
            for clip in track.clips where clip.hasAudioEffects {
                layouts[clip.id] = clip.audioEffectLayout
            }
        }
        return layouts
    }
}

// MARK: - Audio Unit settings

extension Delay {
    /// The longest the Delay unit can wait, in seconds.
    static let maximumTime = 2.0
    /// Kept short of 1, where the echoes would never die away.
    static let maximumFeedback = 0.95
    /// The longest a delay's tail is left room for, in seconds.
    static let maximumTail = 10.0

    /// Puts the delay's values at a time from the clip's start into the unit.
    func apply(to unit: AudioUnitHost, at time: CMTime) {
        unit.set(kDelayParam_DelayTime, min(max(self.time.value(at: time), 0), Self.maximumTime))
        unit.set(kDelayParam_Feedback, min(max(feedback.value(at: time), 0), Self.maximumFeedback) * 100)
        unit.set(kDelayParam_WetDryMix, min(max(mix.value(at: time), 0), 1) * 100)
    }
}

extension Reverb.Room {
    /// How long the room takes to die away (60 dB down) at low frequencies,
    /// in seconds.
    var decay: Double {
        switch self {
        case .smallRoom: 0.6
        case .mediumRoom: 1.2
        case .largeHall: 2.6
        case .cathedral: 6
        case .plate: 1.8
        }
    }

    /// How long it takes at the top of the range, where rooms are duller.
    var decayAtNyquist: Double {
        switch self {
        case .smallRoom: 0.3
        case .mediumRoom: 0.6
        case .largeHall: 1.2
        case .cathedral: 3
        case .plate: 1.5
        }
    }

    /// The spread of the early reflections' delays, in seconds: how big the
    /// room sounds.
    var reflections: ClosedRange<Double> {
        switch self {
        case .smallRoom: 0.002...0.02
        case .mediumRoom: 0.004...0.05
        case .largeHall: 0.008...0.09
        case .cathedral: 0.012...0.15
        case .plate: 0.0005...0.008
        }
    }
}

extension Reverb {
    /// Puts the reverb's mix at a time from the clip's start into the unit.
    func apply(to unit: AudioUnitHost, at time: CMTime) {
        unit.set(kReverb2Param_DryWetMix, min(max(mix.value(at: time), 0), 1) * 100)
    }
}

extension Reverb.Room {
    /// Sets the unit up to sound like the room. Only needed when the room
    /// changes, since the unit works out its delays again for it.
    func apply(to unit: AudioUnitHost) {
        let room = self
        unit.set(kReverb2Param_DecayTimeAt0Hz, room.decay)
        unit.set(kReverb2Param_DecayTimeAtNyquist, room.decayAtNyquist)
        unit.set(kReverb2Param_MinDelayTime, room.reflections.lowerBound)
        unit.set(kReverb2Param_MaxDelayTime, room.reflections.upperBound)
    }
}

extension Equalizer {
    /// The N-band EQ unit's own limits.
    static let gainRange = -96.0...24.0
    static let bandwidthRange = 0.05...5.0

    /// Puts the bands' values at a time from the clip's start into the unit,
    /// which was made with as many bands. `nyquist` is half the sample rate,
    /// the highest a band can sit.
    func apply(to unit: AudioUnitHost, at time: CMTime, nyquist: Double) {
        for (index, band) in bands.enumerated() {
            let offset = AudioUnitParameterID(index)
            unit.set(kAUNBandEQParam_BypassBand + offset, 0)
            unit.set(kAUNBandEQParam_FilterType + offset, Double(kAUNBandEQFilterType_Parametric))
            unit.set(kAUNBandEQParam_Frequency + offset, min(max(band.frequency.value(at: time), 20), nyquist - 1))
            unit.set(kAUNBandEQParam_Gain + offset, band.gain.value(at: time).clamped(to: Self.gainRange))
            unit.set(kAUNBandEQParam_Bandwidth + offset, band.bandwidth.value(at: time).clamped(to: Self.bandwidthRange))
        }
    }
}

extension Gain {
    /// The gain at a time from the clip's start, as a factor to multiply by.
    func factor(at time: CMTime) -> Float {
        Float(pow(10, decibels.value(at: time) / 20))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
