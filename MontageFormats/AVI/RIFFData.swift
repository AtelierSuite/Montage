import Foundation

/// Bytes being laid out for a RIFF file: little-endian integers, four-character
/// codes, and chunks and lists whose sizes are filled in and padded to an even
/// length as they close.
struct RIFFData {
    private(set) var data = Data()

    var count: Int { data.count }

    mutating func fourCC(_ code: String) {
        let bytes = Array(code.utf8)
        precondition(bytes.count == 4, "A four-character code has four ASCII characters")
        data.append(contentsOf: bytes)
    }

    mutating func u8(_ value: UInt8) {
        data.append(value)
    }

    mutating func u16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func i16(_ value: Int16) {
        u16(UInt16(bitPattern: value))
    }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func zeros(_ count: Int) {
        data.append(contentsOf: repeatElement(0, count: count))
    }

    mutating func bytes(_ bytes: some DataProtocol) {
        data.append(contentsOf: bytes)
    }

    /// A chunk: its code, the size of what `body` writes, then that, padded
    /// to an even length.
    mutating func chunk(_ code: String, _ body: (inout RIFFData) -> Void) {
        fourCC(code)
        let sizeOffset = data.count
        u32(0)
        body(&self)
        let size = data.count - sizeOffset - 4
        setU32(UInt32(size), at: sizeOffset)
        if size % 2 == 1 { u8(0) }
    }

    /// A `LIST` of the given type, holding the chunks `body` writes.
    mutating func list(_ type: String, _ body: (inout RIFFData) -> Void) {
        chunk("LIST") { list in
            list.fourCC(type)
            body(&list)
        }
    }

    private mutating func setU32(_ value: UInt32, at offset: Int) {
        withUnsafeBytes(of: value.littleEndian) { bytes in
            data.replaceSubrange(offset..<offset + 4, with: bytes)
        }
    }
}
