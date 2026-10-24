import Synchronization

/// How loud each clip's sound is as it plays, for level meters: the audio
/// taps note the peaks of what they put out, after the clip's effects.
///
/// Made with the composition, with a meter for every clip it plays the sound
/// of; the taps write to the meters from the audio thread, without locking.
public final class AudioLevels: Sendable {
    private let meters: [Clip.ID: AudioMeter]

    init(_ meters: [Clip.ID: AudioMeter] = [:]) {
        self.meters = meters
    }

    /// Whether the clip's sound is being metered.
    public func isMetering(_ clipID: Clip.ID) -> Bool {
        meters[clipID] != nil
    }

    /// The clip's peak level on each side since the last time it was taken,
    /// from 0 (silent) up, where 1 is full scale; nil when the clip isn't
    /// metered. Taking it starts the next peak afresh.
    public func takePeak(of clipID: Clip.ID) -> (left: Float, right: Float)? {
        guard let meter = meters[clipID] else { return nil }
        return (Float(bitPattern: meter.left.exchange(0, ordering: .relaxed)),
                Float(bitPattern: meter.right.exchange(0, ordering: .relaxed)))
    }
}

/// One clip's peaks, as the bits of a `Float` so they can be atomic.
final class AudioMeter: Sendable {
    let left = Atomic<UInt32>(0)
    let right = Atomic<UInt32>(0)

    /// Raises the peaks to these, if they're higher.
    func note(left: Float, right: Float) {
        Self.raise(self.left, to: left)
        Self.raise(self.right, to: right)
    }

    private static func raise(_ peak: borrowing Atomic<UInt32>, to value: Float) {
        // A reading taken in between may lose this peak; a meter can spare it.
        if value > Float(bitPattern: peak.load(ordering: .relaxed)) {
            peak.store(value.bitPattern, ordering: .relaxed)
        }
    }
}
