import Foundation
@testable import MontageFormats
import Testing

struct AAFObjectTests {
    @Test func readsPropertiesAndReferences() throws {
        let children = (0..<5).map { number in
            AAFTestObject(AAFClass.filler).set(AAFProperty.ID.length, int64: Int64(number))
        }
        let root = AAFTestObject(AUID("b3b398a5-1c90-11d4-8053-080036210804"))
            .set(0x0100, string: "Name ✓")
            .set(0x0101, rational: 30000, 1001)
            .set(0x0102, uint32: 7)
            .vector(0x0103, children)
            .weak(0x0104, key: AAFDefinition.sound)
            .strong(0x0105, AAFTestObject(AAFClass.sequence).set(AAFProperty.ID.length, int64: -3))
        var writer = CompoundFileTestWriter()
        writer.root = root.node(named: "Root Entry")
        let file = try AAFFile(writer.data())
        let object = file.root
        #expect(object.string(0x0100) == "Name ✓")
        #expect(object.rational(0x0101) == AAFRational(numerator: 30000, denominator: 1001))
        #expect(object.integer(0x0102) == 7)
        #expect(object.strongReferences(0x0103).map { $0.int64(AAFProperty.ID.length) } == [0, 1, 2, 3, 4])
        #expect(object.strongReferences(0x0103).allSatisfy { $0.isKind(of: AAFClass.segment) })
        #expect(object.weakReferenceKey(0x0104) == AAFDefinition.sound.bytes)
        #expect(object.strongReference(0x0105)?.int64(AAFProperty.ID.length) == -3)
        // Asked for as the wrong kind of property, there's nothing.
        #expect(object.strongReference(0x0100) == nil)
        #expect(object.string(0x0105) == nil)
        #expect(object.strongReferences(0x0999).isEmpty)
    }

    @Test func writesAUIDsAsAAFStoresThem() {
        let auid = AUID("0d010101-0101-1100-060e-2b3402060101")
        #expect(auid == AAFClass.sourceClip)
        #expect(auid.bytes.prefix(8) == [0x01, 0x01, 0x01, 0x0D, 0x01, 0x01, 0x00, 0x11])
        #expect(auid.description == "0d010101-0101-1100-060e-2b3402060101")
    }

    @Test func ignoresDamagedPropertyStreams() {
        #expect(AAFFile.parseProperties(Data()).isEmpty)
        // Big-endian, which no application writes.
        #expect(AAFFile.parseProperties(Data([0x42, 0x20, 1, 0, 1, 0, 0x82, 0, 2, 0, 9, 9])).isEmpty)
        // More entries than the stream has room for.
        #expect(AAFFile.parseProperties(Data([0x4C, 0x20, 0xFF, 0xFF])).isEmpty)
        // A value running past the end stops the read there.
        let properties = AAFFile.parseProperties(Data([0x4C, 0x20, 2, 0, 1, 0, 0x82, 0, 1, 0, 2, 0, 0x82, 0, 9, 0, 7]))
        #expect(properties.count == 1)
        #expect(properties[1]?.data == Data([7]))
    }
}
