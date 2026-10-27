import Foundation
@testable import MontageFormats
import Testing

struct ResolveBlobsTests {
    @Test func readsHex() {
        #expect(ResolveBlobs.hex("00ff10Ab") == Data([0x00, 0xFF, 0x10, 0xAB]))
        #expect(ResolveBlobs.hex("") == Data())
        #expect(ResolveBlobs.hex("abc") == nil)
        #expect(ResolveBlobs.hex("zz") == nil)
    }

    @Test func readsFrameCountsWithTheirRemainders() {
        #expect(ResolveBlobs.frames("86400")?.whole == 86400)
        #expect(ResolveBlobs.frames("86400")?.fraction == 0)
        let half = ResolveBlobWriter.hex(withUnsafeBytes(of: (0.5).bitPattern.littleEndian) { Data($0) })
        #expect(ResolveBlobs.frames("47|\(half)")?.whole == 47)
        #expect(ResolveBlobs.frames("47|\(half)")?.fraction == 0.5)
        #expect(ResolveBlobs.frames("") == nil)
        #expect(ResolveBlobs.frames(nil) == nil)
        #expect(ResolveBlobs.frames("47|00") == nil)
        #expect(ResolveBlobs.frames("frames") == nil)
    }

    @Test func readsFixedSizeValues() {
        // 24.0, as a real export writes it.
        #expect(ResolveBlobs.frameRate(ResolveBlobs.hex("00000000000038400000000000000000")!) == 24)
        #expect(ResolveBlobs.frameRate(ResolveBlobWriter.frameRate(23.976)) == 23.976)
        #expect(ResolveBlobs.frameRate(Data(count: 8)) == nil)
        #expect(ResolveBlobs.frameRate(ResolveBlobWriter.frameRate(-1)) == nil)
        let size = ResolveBlobs.resolution(ResolveBlobWriter.resolution(width: 1920, height: 1080))
        #expect(size?.width == 1920 && size?.height == 1080)
        #expect(ResolveBlobs.resolution(Data(count: 16)) == nil)
        let extents = ResolveBlobs.extents(ResolveBlobWriter.extents(start: 3600, duration: 12.5))
        #expect(extents?.start == 3600 && extents?.duration == 12.5)
    }

    @Test func readsKeyedDictionaries() throws {
        let data = ResolveBlobWriter.keyedDictionary([
            ("NumFrames", .int32(240)), ("FrameRate", .double(25)), ("Name", .string("Clip")),
            ("BlobData", .bytes(Data([1, 2]))),
        ])
        let entries = try ResolveBlobs.keyedDictionary(data)
        #expect(entries.map(\.key) == ["NumFrames", "FrameRate", "Name", "BlobData"])
        #expect(entries[0].value == .integer(240))
        #expect(entries[1].value == .double(25))
        #expect(entries[2].value == .string("Clip"))
        #expect(entries[3].value == .bytes(Data([1, 2])))
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.keyedDictionary(data.prefix(data.count - 1)) }
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.keyedDictionary(Data([0, 0, 0, 2, 0, 0, 0, 0])) }
    }

    @Test func unwrapsMessagesPlainAndInRawZstd() throws {
        let message = ResolveBlobWriter.protobuf([.varint(1, 300), .text(2, "name")])
        #expect(try ResolveBlobs.message(ResolveBlobWriter.envelope(message, zstd: false)) == message)
        #expect(try ResolveBlobs.message(ResolveBlobWriter.envelope(message)) == message)
        let fields = try ResolveBlobs.protobuf(message)
        #expect(fields == [.init(number: 1, varint: 300), .init(number: 2, bytes: Data("name".utf8))])
        // A run-length block.
        var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x04])
        frame.append(contentsOf: [UInt8((4 << 3 | 1 << 1 | 1) & 0xFF), 0, 0, 0x41])
        #expect(try ResolveBlobs.zstd(frame) == Data("AAAA".utf8))
    }

    /// A frame written by the `zstd` tool (level 19) from text built here:
    /// a compressed block with four Huffman streams, FSE-coded weights and
    /// repeated offsets.
    @Test func decodesCompressedZstdBlocks() throws {
        let text = (0..<300).map { "clip \($0 % 17) zoom \($0 * 37 % 101); " }.joined()
        let frame = try #require(ResolveBlobs.hex([
            "28b52ffd641d12b50e0056664b15a025851c03b49d4f31001cf6766e4a924de15513074c0042004200f3683512ec38e6",
            "9946f8c3906516f6c4c61dede64cbc10343bc2ac56f8e806e1369908d622c8add06aa244a6c0d0247150d8702e9510e6",
            "2b64d0282193602008060c06050441402080000001ee683767e285a0d91166b5c24707d9648217f2d0492470e2308e34",
            "042f0ca2c8022da161453a2912ee23337e95ba88bcb5ceabe84fa9f2a97ec4b457bc7c4837136e5ec8432791c089c338",
            "d210bc3088220bb4848615e9a448b88fccf855ea22f2d63aafa23fa5caa7fa11d35ef1f221dd4cb8f3683512ec38e699",
            "46f8c3906516f6c42641229d1409f79119bf4a5d44de5ae755f4a754f9543f62da2b5e3ea49b09771ead46821dc73cd3",
            "087f18b2ccc29ed8b8a3dd9c891782664798d50a1f1d649309018142a811a0f4f637217799c6112414454804d30f730e",
            "155ff6e46e951b08217d3cdaa014be2c9a4703c9229142aca8f03109a08fb9380ac08465859f0114fe914a424c2811dd",
            "8cb23aad0a75358ea108c879912aac9c04a0d21ea90330613ba14f040a6d541616134ae43323514dab426d8d86d00464",
            "d42269085186fc8d3038ecd0eee66c67e6193b73ecd8cb388d5ebb8eda85bdcdc31eed611ff6688fc7cec3b15a01fe2a",
            "be625e59",
        ].joined()))
        #expect(try ResolveBlobs.zstd(frame) == Data(text.utf8))
        #expect(try ResolveBlobs.message(ResolveBlobWriter.envelope(zstdFrame: frame)) == Data(text.utf8))
        // Cut short, or with a byte changed in the middle of its sequences.
        #expect(throws: ResolveBlobs.Failure.self) { try ResolveBlobs.zstd(frame.prefix(frame.count - 40)) }
        #expect(throws: ResolveBlobs.Failure.self) { try ResolveBlobs.zstd(frame, maximumSize: 100) }
    }

    @Test func refusesZstdFramesThatNeedADictionary() {
        let frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x21, 0x05, 0x04, 0x21, 0x00, 0x00, 0x41, 0x41, 0x41, 0x41])
        #expect(throws: ResolveBlobs.Failure.compressed) { try ResolveBlobs.zstd(frame) }
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.zstd(Data([1, 2, 3, 4, 5])) }
    }

    @Test func refusesMalformedMessages() {
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.protobuf(Data([0x0A, 0x05, 0x01])) }
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.protobuf(Data([0x00])) }
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.message(Data([0, 0, 0, 1, 0, 0, 0, 9, 0x80])) }
        #expect(throws: ResolveBlobs.Failure.malformed) { try ResolveBlobs.message(Data([0, 0, 0, 1, 0, 0, 0, 1, 0x7F])) }
    }

    @Test func readsAMediaPathFromAClipValue() throws {
        #expect(try ResolveBlobs.mediaPath(fromClip: ResolveBlobWriter.clip(folder: "/Volumes/Media", name: "A.mov"))
            == "/Volumes/Media/A.mov")
        #expect(try ResolveBlobs.mediaPath(fromClip: ResolveBlobWriter.clip(folder: "D:\\Footage", name: "B.mov"))
            == "D:\\Footage\\B.mov")
    }

    @Test func readsMarkers() throws {
        let markers = try ResolveBlobs.markers(fromFieldsBlob: ResolveBlobWriter.markers([
            (frame: 48, name: "Cue", note: "Music in"), (frame: 0, name: "", note: ""),
        ]))
        #expect(markers == [
            .init(frame: 48, name: "Cue", note: "Music in"), .init(frame: 0, name: "", note: ""),
        ])
        #expect(throws: ResolveBlobs.Failure.malformed) {
            try ResolveBlobs.markers(fromFieldsBlob: ResolveBlobWriter.keyedDictionary([("Other", .int32(1))]))
        }
    }
}
