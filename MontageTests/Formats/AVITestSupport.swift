import AudioToolbox
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
@testable import MontageFormats
import Testing
import UniformTypeIdentifiers
import VideoToolbox

extension Tag {
    /// Tests that write files of a gigabyte or more, run only when the
    /// `MONTAGE_LARGE_FILE_TESTS` environment variable is set.
    @Tag static var largeFile: Self
}

// MARK: Reading RIFF

/// A chunk in a RIFF file, read back to check how it was written. Lists keep
/// their children; other chunks keep their data, except for frames and audio,
/// which keep only their first bytes, so large files can be read.
struct RIFFChunk {
    var id: String
    /// The type of a `RIFF` or `LIST`.
    var listType: String?
    /// Where the chunk's header starts.
    var offset: UInt64
    var size: UInt32
    var children: [RIFFChunk] = []
    var data = Data()

    var dataOffset: UInt64 { offset + 8 }

    func child(_ id: String, type: String? = nil) -> RIFFChunk? {
        children.first { $0.id == id && (type == nil || $0.listType == type) }
    }

    func children(_ id: String) -> [RIFFChunk] {
        children.filter { $0.id == id }
    }

    func u16(at offset: Int) -> UInt16 {
        data.withUnsafeBytes { UInt16(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)) }
    }

    func u32(at offset: Int) -> UInt32 {
        data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
    }

    func u64(at offset: Int) -> UInt64 {
        data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
    }

    func fourCC(at offset: Int) -> String {
        String(decoding: data[data.startIndex + offset..<data.startIndex + offset + 4], as: UTF8.self)
    }

    var isMedia: Bool { id.hasSuffix("dc") || id.hasSuffix("wb") }
}

struct RIFFFile {
    var url: URL
    var chunks: [RIFFChunk]
    var fileSize: UInt64

    static let prefixLength = 8

    init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        fileSize = try handle.seekToEnd()
        chunks = try Self.chunks(in: handle, from: 0, to: fileSize)
    }

    /// Reads the chunk header at `offset`, wherever an index says one is.
    func chunkHeader(at offset: UInt64) throws -> (id: String, size: UInt32) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        let header = try handle.read(upToCount: 8) ?? Data()
        let chunk = RIFFChunk(id: "", offset: offset, size: 0, data: header)
        return (chunk.fourCC(at: 0), chunk.u32(at: 4))
    }

    private static func chunks(in handle: FileHandle, from start: UInt64, to end: UInt64) throws -> [RIFFChunk] {
        var chunks: [RIFFChunk] = []
        var offset = start
        while offset + 8 <= end {
            try handle.seek(toOffset: offset)
            let header = RIFFChunk(id: "", offset: 0, size: 0, data: try handle.read(upToCount: 12) ?? Data())
            var chunk = RIFFChunk(id: header.fourCC(at: 0), offset: offset, size: header.u32(at: 4))
            let dataEnd = offset + 8 + UInt64(chunk.size)
            if chunk.id == "RIFF" || chunk.id == "LIST" {
                chunk.listType = header.fourCC(at: 8)
                chunk.children = try Self.chunks(in: handle, from: offset + 12, to: dataEnd)
            } else {
                try handle.seek(toOffset: offset + 8)
                let length = chunk.isMedia ? min(Int(chunk.size), prefixLength) : Int(chunk.size)
                chunk.data = try handle.read(upToCount: length) ?? Data()
            }
            chunks.append(chunk)
            offset = dataEnd + UInt64(chunk.size % 2)
        }
        return chunks
    }
}

// MARK: Synthesizing media

enum TestMedia {
    /// A frame with a square moving across a gradient, so every frame differs.
    static func image(width: Int, height: Int, frame: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        draw(in: context, width: width, height: height, frame: frame)
        return context.makeImage()!
    }

    static func draw(in context: CGContext, width: Int, height: Int, frame: Int) {
        let hue = CGFloat(frame % 60) / 60
        context.setFillColor(CGColor(red: hue, green: 0.4, blue: 1 - hue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let side = CGFloat(min(width, height)) / 4
        let x = CGFloat(frame * 4 % max(1, width - Int(side)))
        context.fill(CGRect(x: x, y: CGFloat(height) / 2 - side / 2, width: side, height: side))
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.8) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A frame of random noise, which JPEG can hardly compress.
    static func noiseJPEG(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        let pixels = context.data!.bindMemory(to: UInt32.self, capacity: width * height)
        var generator = SystemRandomNumberGenerator()
        for index in 0..<width * height { pixels[index] = generator.next() }
        return jpeg(context.makeImage()!, quality: 1)
    }

    /// A 440 Hz tone as 16-bit signed little-endian samples, interleaved.
    static func sine(samples: Int, from start: Int = 0, sampleRate: Int, channels: Int) -> Data {
        var data = Data(capacity: samples * channels * 2)
        for sample in start..<start + samples {
            let value = Int16(sin(2 * .pi * 440 * Double(sample) / Double(sampleRate)) * 12_000)
            for _ in 0..<channels {
                withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    /// PCM in a sample buffer, as an `AVAssetReaderOutput` would hand it over.
    static func pcmSampleBuffer(_ pcm: Data, sampleRate: Int, channels: Int) throws -> CMSampleBuffer {
        let bytesPerFrame = UInt32(channels * 2)
        var format = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame, mFramesPerPacket: 1, mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 16, mReserved: 0)
        var description: CMAudioFormatDescription?
        try check(CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &format, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description))

        var block: CMBlockBuffer?
        try check(CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: pcm.count, blockAllocator: nil, customBlockSource: nil,
            offsetToData: 0, dataLength: pcm.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block))
        try pcm.withUnsafeBytes { bytes in
            try check(CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: pcm.count))
        }

        var sampleBuffer: CMSampleBuffer?
        try check(CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: nil, dataBuffer: block!, formatDescription: description!,
            sampleCount: pcm.count / Int(bytesPerFrame), presentationTimeStamp: .zero, packetDescriptions: nil,
            sampleBufferOut: &sampleBuffer))
        return sampleBuffer!
    }

    /// Encodes frames to H.264 with VideoToolbox, handing each encoded frame
    /// to `output` from the encoder's own thread, in decode order.
    static func encodeH264(
        width: Int, height: Int, frames: Int, frameRate: AVIWriter.FrameRate, keyframeInterval: Int,
        output: @escaping @Sendable (CMSampleBuffer) -> Void
    ) throws {
        var session: VTCompressionSession?
        try check(VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session))
        let encoder = session!
        defer { VTCompressionSessionInvalidate(encoder) }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyframeInterval as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)

        let duration = CMTime(value: CMTimeValue(frameRate.denominator), timescale: CMTimeScale(frameRate.numerator))
        for frame in 0..<frames {
            var pixelBuffer: CVPixelBuffer?
            try check(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &pixelBuffer))
            let buffer = pixelBuffer!
            CVPixelBufferLockBaseAddress(buffer, [])
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            draw(in: context, width: width, height: height, frame: frame)
            CVPixelBufferUnlockBaseAddress(buffer, [])

            try check(VTCompressionSessionEncodeFrame(
                encoder, imageBuffer: buffer, presentationTimeStamp: CMTimeMultiply(duration, multiplier: Int32(frame)),
                duration: duration, frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sampleBuffer in
                if status == noErr, let sampleBuffer { output(sampleBuffer) }
            })
        }
        try check(VTCompressionSessionCompleteFrames(encoder, untilPresentationTimeStamp: .invalid))
    }

    struct StatusError: Error {
        var status: OSStatus
    }

    static func check(_ status: OSStatus) throws {
        guard status == noErr else { throw StatusError(status: status) }
    }
}

// MARK: FFmpeg

/// FFmpeg from Homebrew, when it's installed, to check that files are read by
/// something other than our own parser.
enum FFmpeg {
    static let ffprobe = URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe")
    static let ffmpeg = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")

    static var isAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ffprobe.path)
            && FileManager.default.isExecutableFile(atPath: ffmpeg.path)
    }

    struct Result {
        var status: Int32
        var output: Data
        var errors: String
    }

    static func run(_ tool: URL, _ arguments: [String]) throws -> Result {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appending(path: "out")
        let errorsURL = directory.appending(path: "err")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorsURL.path, contents: nil)

        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = try FileHandle(forWritingTo: outputURL)
        process.standardError = try FileHandle(forWritingTo: errorsURL)
        try process.run()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: try Data(contentsOf: outputURL),
            errors: String(decoding: try Data(contentsOf: errorsURL), as: UTF8.self))
    }

    struct Probe {
        var formatName: String
        var duration: Double
        var streams: [[String: Any]]

        func stream(_ type: String) -> [String: Any]? {
            streams.first { $0["codec_type"] as? String == type }
        }
    }

    /// What ffprobe makes of a file. With `countFrames`, it decodes every
    /// frame to count them; otherwise it counts packets.
    static func probe(_ url: URL, countFrames: Bool = true) throws -> (probe: Probe, errors: String) {
        let result = try run(ffprobe, [
            "-v", "error", countFrames ? "-count_frames" : "-count_packets",
            "-show_entries",
            "stream=codec_type,codec_name,codec_tag_string,width,height,r_frame_rate,nb_frames,nb_read_frames,"
                + "nb_read_packets,sample_rate,channels,duration:format=format_name,duration",
            "-of", "json", url.path,
        ])
        let json = try JSONSerialization.jsonObject(with: result.output) as? [String: Any] ?? [:]
        let format = json["format"] as? [String: Any] ?? [:]
        let probe = Probe(
            formatName: format["format_name"] as? String ?? "",
            duration: Double(format["duration"] as? String ?? "") ?? 0,
            streams: json["streams"] as? [[String: Any]] ?? [])
        return (probe, result.errors)
    }

    /// Decodes the whole file, returning what FFmpeg complains about.
    static func decodeErrors(_ url: URL) throws -> String {
        let result = try run(ffmpeg, ["-v", "error", "-i", url.path, "-f", "null", "-"])
        return result.status == 0 ? result.errors : "exit \(result.status): " + result.errors
    }
}
