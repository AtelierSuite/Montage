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

    @Test func refusesCompressedZstdBlocks() {
        var frame = Data([0x28, 0xB5, 0x2F, 0xFD, 0x20, 0x04])
        frame.append(contentsOf: [UInt8(4 << 3 | 2 << 1 | 1), 0, 0, 1, 2, 3, 4])
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
