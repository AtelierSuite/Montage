import Foundation

/// An AAF identifier: a 16-byte UUID or SMPTE label, as AAF stores it, with
/// its first three fields little-endian.
struct AUID: Hashable, CustomStringConvertible {
    let bytes: [UInt8]

    init?(bytes: some Collection<UInt8>) {
        guard bytes.count == 16 else { return nil }
        self.bytes = Array(bytes)
    }

    /// From the usual written form, such as
    /// "0d010101-0101-1100-060e-2b3402060101".
    init(_ string: StaticString) {
        let hex = string.description.filter(\.isHexDigit)
        precondition(hex.count == 32, "An AUID has 32 hex digits")
        var written: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            written.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        // Data1, Data2 and Data3 are stored little-endian.
        bytes = written[0..<4].reversed() + written[4..<6].reversed() + written[6..<8].reversed() + written[8...]
    }

    var description: String {
        let written = bytes[0..<4].reversed() + bytes[4..<6].reversed() + bytes[6..<8].reversed() + bytes[8...]
        let hex = written.map { String(format: "%02x", $0) }.joined()
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(hex[hex.index(hex.startIndex, offsetBy: range.lowerBound)..<hex.index(hex.startIndex, offsetBy: range.upperBound)])
        }
        return parts.joined(separator: "-")
    }
}

/// An AAF file's objects, read out of its compound file.
///
/// Each object is a storage, its class in the storage's class ID, and its
/// properties in a stream named "properties" inside it. A property holds a
/// value, or refers to other objects: strongly, to the storages in its own
/// storage that it owns, or weakly, by the key (such as an AUID) of an
/// object owned somewhere else, such as a definition in the dictionary.
///
/// Only the little-endian binary form is read, which is what every
/// application writes; AAF's XML form isn't.
final class AAFFile {
    let storage: CompoundFile
    private var propertiesByEntry: [Int: [UInt16: AAFProperty]] = [:]
    /// Each class's parent, for telling whether an object is of a kind.
    private var parents: [AUID: AUID] = AAFClass.parents

    init(_ data: Data) throws(CompoundFile.ReadError) {
        storage = try CompoundFile(data)
        readClassDefinitions()
    }

    var root: AAFObject { object(at: 0) }

    func object(at entry: Int) -> AAFObject {
        let classID = storage.entries.indices.contains(entry) ? AUID(bytes: storage.entries[entry].classID) : nil
        return AAFObject(file: self, entry: entry, classID: classID ?? AAFClass.interchangeObject)
    }

    /// Whether an object is of a class, or one derived from it.
    func isKind(_ classID: AUID, of wanted: AUID) -> Bool {
        var current: AUID? = classID
        // Past any real hierarchy's depth, the file's definitions loop.
        for _ in 0..<32 {
            guard let id = current else { return false }
            if id == wanted { return true }
            current = parents[id]
        }
        return false
    }

    func properties(of entry: Int) -> [UInt16: AAFProperty] {
        if let cached = propertiesByEntry[entry] { return cached }
        var result: [UInt16: AAFProperty] = [:]
        if let data = try? storage.stream(named: "properties", in: entry) {
            result = Self.parseProperties(data)
        }
        propertiesByEntry[entry] = result
        return result
    }

    /// The properties stream: a byte order ('L' for little-endian), a
    /// version, a count, then each property's ID, stored form and size,
    /// and after them all, each one's bytes in turn.
    static func parseProperties(_ data: Data) -> [UInt16: AAFProperty] {
        let bytes = ByteView(data)
        guard bytes.count >= 4, bytes.u8(0) == 0x4C else { return [:] }
        let count = Int(bytes.u16(2))
        var offset = 4 + count * 6
        guard offset <= bytes.count else { return [:] }
        var result: [UInt16: AAFProperty] = [:]
        for index in 0..<count {
            let entry = 4 + index * 6
            let size = Int(bytes.u16(entry + 4))
            guard offset + size <= bytes.count else { break }
            let pid = bytes.u16(entry)
            result[pid] = AAFProperty(form: bytes.u16(entry + 2), data: bytes.data.subdata(in: offset..<offset + size))
            offset += size
        }
        return result
    }

    /// Classes the file defines for itself, from its meta-dictionary, so an
    /// application's own subclass of, say, a source clip is still read as one.
    private func readClassDefinitions() {
        guard let metaDictionary = root.strongReference(AAFProperty.ID.metaDictionary) else { return }
        for definition in metaDictionary.strongReferences(AAFProperty.ID.classDefinitions) {
            guard let id = definition.auid(AAFProperty.ID.metaIdentification),
                  let parent = definition.weakReferenceKey(AAFProperty.ID.parentClass).flatMap({ AUID(bytes: $0) }),
                  parent != id, parents[id] == nil else { continue }
            parents[id] = parent
        }
    }
}

/// One property's stored bytes.
struct AAFProperty {
    /// How the property is stored: a value, a stream, or a reference.
    enum Form {
        static let data: UInt16 = 0x82
        static let strongReference: UInt16 = 0x22
        static let strongReferenceVector: UInt16 = 0x32
        static let strongReferenceSet: UInt16 = 0x3A
        static let weakReference: UInt16 = 0x02
        static let weakReferenceStoredObjectID: UInt16 = 0x03
    }

    var form: UInt16
    var data: Data
}

/// An object in an AAF file, read lazily: its properties are read the first
/// time they're asked for, and kept by the file.
struct AAFObject {
    let file: AAFFile
    /// Its storage's entry in the compound file's directory.
    let entry: Int
    let classID: AUID

    var properties: [UInt16: AAFProperty] { file.properties(of: entry) }

    func isKind(of wanted: AUID) -> Bool { file.isKind(classID, of: wanted) }

    func has(_ pid: UInt16) -> Bool { properties[pid] != nil }

    // MARK: - Values

    func data(_ pid: UInt16) -> Data? {
        guard let property = properties[pid], property.form == AAFProperty.Form.data else { return nil }
        return property.data
    }

    func int64(_ pid: UInt16) -> Int64? {
        guard let data = data(pid), data.count == 8 else { return nil }
        return ByteView(data).i64(0)
    }

    /// An unsigned or signed number of up to 64 bits, as written.
    func integer(_ pid: UInt16) -> Int64? {
        guard let data = data(pid) else { return nil }
        let bytes = ByteView(data)
        switch data.count {
        case 1: return Int64(bytes.u8(0))
        case 2: return Int64(bytes.u16(0))
        case 4: return Int64(bytes.u32(0))
        case 8: return bytes.i64(0)
        default: return nil
        }
    }

    func bool(_ pid: UInt16) -> Bool? {
        guard let data = data(pid), data.count == 1 else { return nil }
        return data[data.startIndex] != 0
    }

    /// A rational, numerator then denominator, each a signed 32-bit number.
    func rational(_ pid: UInt16) -> AAFRational? {
        guard let data = data(pid), data.count == 8 else { return nil }
        let bytes = ByteView(data)
        return AAFRational(numerator: bytes.i32(0), denominator: bytes.i32(4))
    }

    /// Text, stored as null-terminated UTF-16.
    func string(_ pid: UInt16) -> String? {
        data(pid).map(Self.utf16)
    }

    func auid(_ pid: UInt16) -> AUID? {
        data(pid).flatMap { AUID(bytes: $0) }
    }

    /// A mob ID, 32 bytes, kept as they are to compare.
    func mobID(_ pid: UInt16) -> MobID? {
        guard let data = data(pid), data.count == 32 else { return nil }
        return MobID(bytes: Array(data))
    }

    /// A value of any type, such as a parameter's, as a number where it is
    /// one: the value is written after a byte order and its type's AUID.
    func indirectNumber(_ pid: UInt16) -> Double? {
        guard let data = data(pid), data.count > 17, data[data.startIndex] == 0x4C,
              let type = AUID(bytes: data.dropFirst().prefix(16)) else { return nil }
        let value = ByteView(data.dropFirst(17))
        switch type {
        case AAFType.rational:
            guard value.count == 8, value.i32(4) != 0 else { return nil }
            return Double(value.i32(0)) / Double(value.i32(4))
        case AAFType.int8: return value.count == 1 ? Double(Int8(bitPattern: value.u8(0))) : nil
        case AAFType.uint8: return value.count == 1 ? Double(value.u8(0)) : nil
        case AAFType.int16: return value.count == 2 ? Double(Int16(bitPattern: value.u16(0))) : nil
        case AAFType.uint16: return value.count == 2 ? Double(value.u16(0)) : nil
        case AAFType.int32: return value.count == 4 ? Double(value.i32(0)) : nil
        case AAFType.uint32: return value.count == 4 ? Double(value.u32(0)) : nil
        case AAFType.int64: return value.count == 8 ? Double(value.i64(0)) : nil
        default: return nil
        }
    }

    // MARK: - References

    /// The object a strong reference owns: a storage inside this one, named
    /// by the property.
    func strongReference(_ pid: UInt16) -> AAFObject? {
        guard let property = properties[pid], property.form == AAFProperty.Form.strongReference else { return nil }
        return child(named: Self.utf16(property.data))
    }

    /// The objects a strong reference vector or set owns, in order. An
    /// index stream lists the keys that tell their storages apart.
    func strongReferences(_ pid: UInt16) -> [AAFObject] {
        guard let property = properties[pid],
              property.form == AAFProperty.Form.strongReferenceVector || property.form == AAFProperty.Form.strongReferenceSet
        else { return [] }
        let name = Self.utf16(property.data)
        guard !name.isEmpty, let index = try? file.storage.stream(named: name + " index", in: entry) else { return [] }
        let bytes = ByteView(index)
        let count = Int(bytes.u32(0))
        var keys: [UInt32] = []
        if property.form == AAFProperty.Form.strongReferenceVector {
            // Count, next free key, last free key, then each local key.
            let available = max(0, (bytes.count - 12) / 4)
            keys = (0..<min(count, available)).map { bytes.u32(12 + $0 * 4) }
        } else {
            // As a vector, then the key property's ID and size, then each
            // entry's local key, a reference count and the key itself.
            let keySize = Int(bytes.u8(14))
            let stride = 8 + keySize
            let available = max(0, (bytes.count - 15) / stride)
            keys = (0..<min(count, available)).map { bytes.u32(15 + $0 * stride) }
        }
        return keys.compactMap { child(named: name + "{" + String($0, radix: 16) + "}") }
    }

    /// The key a weak reference names its object by, such as a definition's
    /// AUID: written after the index of the set it's in, the key's
    /// property and its size.
    func weakReferenceKey(_ pid: UInt16) -> [UInt8]? {
        guard let property = properties[pid],
              property.form == AAFProperty.Form.weakReference || property.form == AAFProperty.Form.weakReferenceStoredObjectID,
              property.data.count >= 5 else { return nil }
        let bytes = ByteView(property.data)
        let size = Int(bytes.u8(4))
        guard property.data.count >= 5 + size else { return nil }
        return Array(bytes.data[5..<5 + size])
    }

    /// The strong references among the properties, whatever their IDs: for
    /// properties whose IDs are given out by the file, as extensions' are.
    var allStrongReferenceVectors: [AAFObject] {
        properties.keys.sorted().flatMap { strongReferences($0) }
    }

    private func child(named name: String) -> AAFObject? {
        guard !name.isEmpty, let index = file.storage.child(named: name, of: entry),
              file.storage.entries[index].kind == .storage else { return nil }
        return file.object(at: index)
    }

    static func utf16(_ data: Data) -> String {
        let bytes = ByteView(data)
        var units: [UInt16] = []
        for index in 0..<data.count / 2 {
            let unit = bytes.u16(index * 2)
            if unit == 0 { break }
            units.append(unit)
        }
        return String(decoding: units, as: UTF16.self)
    }
}

/// A mob's ID: a 32-byte SMPTE UMID.
struct MobID: Hashable {
    let bytes: [UInt8]

    var isZero: Bool { bytes.allSatisfy { $0 == 0 } }

    /// The ID as hex, to key media by.
    var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

struct AAFRational: Equatable {
    var numerator: Int32
    var denominator: Int32
}
