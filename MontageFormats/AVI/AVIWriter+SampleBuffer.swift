import AudioToolbox
import CoreMedia
import Foundation

extension AVIWriter {
    /// Appends the next video frame from an encoded sample buffer, such as
    /// one from a `VTCompressionSession`'s output handler: JPEG for a Motion
    /// JPEG stream, or H.264 for an H.264 stream, whose length-prefixed NAL
    /// units are rewritten as Annex B with the parameter sets from the
    /// buffer's format description in front of keyframes.
    public func appendVideo(_ sampleBuffer: CMSampleBuffer) throws {
        let frame: (data: Data, isKeyframe: Bool)
        switch videoSettings.codec {
        case .motionJPEG:
            guard sampleBuffer.formatDescription?.mediaSubType == .jpeg else {
                throw AVIWriterError.unsupportedMedia
            }
            frame = (try SampleBufferBytes.data(of: sampleBuffer), true)
        case .h264:
            frame = try H264AnnexB.frame(from: sampleBuffer)
        }
        try appendVideoFrame(frame.data, isKeyframe: frame.isKeyframe)
    }

    /// Appends the audio in a sample buffer of linear PCM, such as one from an
    /// `AVAssetReaderOutput` set up for 16-bit signed little-endian interleaved
    /// samples at the stream's sample rate and channel count.
    public func appendAudio(_ sampleBuffer: CMSampleBuffer) throws {
        guard let audio = audioSettings,
              let description = sampleBuffer.formatDescription,
              let format = description.audioStreamBasicDescription
        else { throw AVIWriterError.unsupportedMedia }
        let flags = format.mFormatFlags
        guard format.mFormatID == kAudioFormatLinearPCM,
              flags & kAudioFormatFlagIsSignedInteger != 0,
              flags & (kAudioFormatFlagIsFloat | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsNonInterleaved) == 0,
              format.mBitsPerChannel == 16,
              Int(format.mChannelsPerFrame) == audio.channels,
              format.mSampleRate == Double(audio.sampleRate)
        else { throw AVIWriterError.unsupportedMedia }
        try appendAudio(try SampleBufferBytes.data(of: sampleBuffer))
    }
}

enum SampleBufferBytes {
    /// A copy of the bytes in a sample buffer's data buffer.
    static func data(of sampleBuffer: CMSampleBuffer) throws(AVIWriterError) -> Data {
        guard let block = sampleBuffer.dataBuffer else { throw .unsupportedMedia }
        let length = CMBlockBufferGetDataLength(block)
        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return noErr }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard status == noErr else { throw .unsupportedMedia }
        return data
    }
}

/// Rewrites H.264 from the length-prefixed form in MP4 and in sample buffers
/// (AVCC) to the start-code form AVI keeps it in (Annex B).
enum H264AnnexB {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    private enum NALType {
        static let sps: UInt8 = 7
    }

    /// The frame in a sample buffer of H.264, with its parameter sets in
    /// front of it when it's a keyframe that doesn't carry them already.
    static func frame(from sampleBuffer: CMSampleBuffer) throws(AVIWriterError) -> (data: Data, isKeyframe: Bool) {
        guard let description = sampleBuffer.formatDescription,
              description.mediaSubType == .h264,
              sampleBuffer.numSamples == 1
        else { throw .unsupportedMedia }

        var parameterSetCount = 0
        var lengthSize: Int32 = 0
        guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            description, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount, nalUnitHeaderLengthOut: &lengthSize
        ) == noErr else { throw .unsupportedMedia }

        var parameterSets: [Data] = []
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                description, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { throw .unsupportedMedia }
            parameterSets.append(Data(bytes: pointer, count: size))
        }

        let isKeyframe = !isNotSync(sampleBuffer)
        let units = try nalUnits(in: try SampleBufferBytes.data(of: sampleBuffer), lengthSize: Int(lengthSize))
        return (annexB(units, parameterSets: isKeyframe ? parameterSets : []), isKeyframe)
    }

    /// Splits length-prefixed NAL units, each after a big-endian length of
    /// `lengthSize` bytes.
    static func nalUnits(in data: Data, lengthSize: Int) throws(AVIWriterError) -> [Data] {
        guard [1, 2, 4].contains(lengthSize) else { throw .unsupportedMedia }
        let bytes = [UInt8](data)
        var units: [Data] = []
        var offset = 0
        while offset < bytes.count {
            guard offset + lengthSize <= bytes.count else { throw .unsupportedMedia }
            let length = bytes[offset..<offset + lengthSize].reduce(0) { $0 << 8 | Int($1) }
            offset += lengthSize
            guard length <= bytes.count - offset else { throw .unsupportedMedia }
            units.append(Data(bytes[offset..<offset + length]))
            offset += length
        }
        return units
    }

    /// Joins NAL units with start codes, leading with the parameter sets
    /// unless the units already have an SPS of their own.
    static func annexB(_ units: [Data], parameterSets: [Data]) -> Data {
        let hasSPS = units.contains { ($0.first ?? 0) & 0x1F == NALType.sps }
        var stream = Data()
        for unit in (hasSPS ? [] : parameterSets) + units where !unit.isEmpty {
            stream.append(contentsOf: startCode)
            stream.append(unit)
        }
        return stream
    }

    private static func isNotSync(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[CFString: Any]], let first = attachments.first
        else { return false }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
    }
}
