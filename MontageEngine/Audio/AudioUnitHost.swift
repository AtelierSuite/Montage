import AudioToolbox
import AVFoundation

/// One of Apple's built-in effect Audio Units, run in place over buffers of
/// a tap's audio.
///
/// Made and set up off the audio thread (in a tap's `prepare`); `render`,
/// `set` and `reset` are what the audio thread calls, and none of them
/// allocate. The unit pulls its input from a copy of the buffers it renders
/// over, so it can write its output straight back into them.
final class AudioUnitHost {
    private let unit: AudioUnit
    /// The audio being rendered, copied out of the buffers the unit writes
    /// into, for the unit's input callback to hand it.
    private let input: UnsafeMutableAudioBufferListPointer
    private let maxFrames: Int
    private var timeStamp = AudioTimeStamp()

    /// A unit of the subtype, set up for audio in `format` (32-bit float, one
    /// buffer per channel) in pieces of up to `maxFrames`. `configure` sets
    /// properties that have to be set before the unit is initialized. Nil
    /// when the unit can't be made or doesn't take the format.
    init?(subtype: OSType, format: AudioStreamBasicDescription, maxFrames: Int, configure: (AudioUnit) -> Void = { _ in }) {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else { return nil }
        var instance: AudioUnit?
        guard AudioComponentInstanceNew(component, &instance) == noErr, let instance else { return nil }
        unit = instance
        self.maxFrames = maxFrames

        let channels = Int(format.mChannelsPerFrame)
        input = AudioBufferList.allocate(maximumBuffers: channels)
        for index in 0..<channels {
            let bytes = maxFrames * MemoryLayout<Float>.size
            input[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(bytes), mData: UnsafeMutableRawPointer.allocate(
                byteCount: bytes, alignment: MemoryLayout<Float>.alignment
            ))
        }

        var format = format
        var frames = UInt32(maxFrames)
        var callback = AURenderCallbackStruct(inputProc: { refCon, _, _, _, frameCount, ioData in
            guard let ioData else { return kAudio_ParamError }
            let host = Unmanaged<AudioUnitHost>.fromOpaque(refCon).takeUnretainedValue()
            host.provideInput(to: UnsafeMutableAudioBufferListPointer(ioData), frameCount: Int(frameCount))
            return noErr
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        let formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, formatSize)
        if status == noErr {
            status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, formatSize)
        }
        if status == noErr {
            status = AudioUnitSetProperty(
                unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &frames, UInt32(MemoryLayout<UInt32>.size)
            )
        }
        if status == noErr {
            status = AudioUnitSetProperty(
                unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)
            )
        }
        if status == noErr {
            configure(unit)
            status = AudioUnitInitialize(unit)
        }
        guard status == noErr else { return nil }
        timeStamp.mFlags = .sampleTimeValid
    }

    deinit {
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        for buffer in input { buffer.mData?.deallocate() }
        free(input.unsafeMutablePointer)
    }

    /// Sets one of the unit's parameters, in the global scope.
    func set(_ parameter: AudioUnitParameterID, _ value: Double) {
        AudioUnitSetParameter(unit, parameter, kAudioUnitScope_Global, 0, AudioUnitParameterValue(value), 0)
    }

    /// Lets go of what the unit holds from audio it has had, such as a
    /// reverb's tail, for audio that doesn't follow on from it.
    func reset() {
        AudioUnitReset(unit, kAudioUnitScope_Global, 0)
    }

    /// Runs the unit over the buffers, replacing what's in them with its
    /// output. The buffers have as many channels as the format the unit was
    /// made for, and no more than `maxFrames`.
    func render(_ buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        guard frameCount > 0, frameCount <= maxFrames, buffers.count == input.count else { return }
        let bytes = frameCount * MemoryLayout<Float>.size
        for index in 0..<buffers.count {
            guard let source = buffers[index].mData, let copy = input[index].mData else { return }
            copy.copyMemory(from: source, byteCount: bytes)
        }
        var flags = AudioUnitRenderActionFlags()
        let status = AudioUnitRender(unit, &flags, &timeStamp, 0, UInt32(frameCount), buffers.unsafeMutablePointer)
        timeStamp.mSampleTime += Double(frameCount)
        // A unit that failed leaves the buffers as they were: copy the dry
        // audio back rather than pass on whatever is half written.
        if status != noErr {
            for index in 0..<buffers.count {
                buffers[index].mData?.copyMemory(from: input[index].mData!, byteCount: bytes)
            }
        }
    }

    /// The unit asking for its input: the audio copied out in `render`.
    private func provideInput(to buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        let bytes = min(frameCount, maxFrames) * MemoryLayout<Float>.size
        for index in 0..<min(buffers.count, input.count) {
            if let destination = buffers[index].mData {
                destination.copyMemory(from: input[index].mData!, byteCount: bytes)
            } else {
                buffers[index].mData = input[index].mData
            }
            buffers[index].mDataByteSize = UInt32(bytes)
        }
    }
}
