import AVFoundation
import MediaToolbox

/// Changes one composition track's sound as it plays or is read, from inside
/// an `MTAudioProcessingTap` (see `AudioTap`).
///
/// `prepare` and `unprepare` are called off the audio thread, and may allocate
/// and set things up. `process` is called on the real-time audio thread: it
/// mustn't allocate, take a lock it could wait on, or touch Swift concurrency.
/// The calls never overlap, so a processor needs no locking of its own.
protocol AudioTapProcessor: AnyObject, Sendable {
    /// Called before the first `process`, and again whenever the audio
    /// machinery is rebuilt, with the format the audio will come in and the
    /// most frames a `process` will be asked for.
    func prepare(format: AudioStreamBasicDescription, maxFrames: Int)
    /// Called once processing has stopped, paired with `prepare`.
    func unprepare()
    /// Changes the audio in `buffers` in place. `timeRange` is where the audio
    /// is in the composition, and `isDiscontinuity` says it doesn't follow on
    /// from the last call (playback started, or sought), so state such as a
    /// reverb's should be let go of.
    func process(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int, timeRange: CMTimeRange, isDiscontinuity: Bool)
}

/// Makes `MTAudioProcessingTap`s that hand their audio to an
/// `AudioTapProcessor`, for an audio mix's input parameters.
///
/// The tap's C callbacks find the processor through the tap's storage, which
/// holds it retained from the tap's creation until the tap is finalized, so
/// the processor lives exactly as long as the tap.
enum AudioTap {
    /// A tap for the processor, or nil if one couldn't be made.
    static func make(_ processor: any AudioTapProcessor) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: Unmanaged.passRetained(Box(processor)).toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, format in
                Box.processor(of: tap).prepare(format: format.pointee, maxFrames: maxFrames)
            },
            unprepare: { tap in
                Box.processor(of: tap).unprepare()
            },
            process: { tap, frameCount, _, bufferList, frameCountOut, flagsOut in
                var flags: MTAudioProcessingTapFlags = 0
                var timeRange = CMTimeRange.invalid
                // In place: the buffer list comes without buffers, and the
                // source's are handed back in it.
                let status = MTAudioProcessingTapGetSourceAudio(tap, frameCount, bufferList, &flags, &timeRange, frameCountOut)
                flagsOut.pointee = flags
                guard status == noErr, frameCountOut.pointee > 0 else { return }
                Box.processor(of: tap).process(
                    UnsafeMutableAudioBufferListPointer(bufferList), frameCount: frameCountOut.pointee, timeRange: timeRange,
                    isDiscontinuity: flags & kMTAudioProcessingTapFlag_StartOfStream != 0
                )
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr else {
            // The tap was never made, so it won't let go of the processor.
            if let clientInfo = callbacks.clientInfo { Unmanaged<Box>.fromOpaque(clientInfo).release() }
            return nil
        }
        return tap
    }

    /// The processor, as a class the tap's storage can point at.
    private final class Box {
        let processor: any AudioTapProcessor

        init(_ processor: any AudioTapProcessor) {
            self.processor = processor
        }

        static func processor(of tap: MTAudioProcessingTap) -> any AudioTapProcessor {
            Unmanaged<Box>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().processor
        }
    }
}
