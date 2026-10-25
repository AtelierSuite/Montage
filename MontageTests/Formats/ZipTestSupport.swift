import Foundation
@testable import MontageFormats

/// Writes small ZIP archives at test time, so the reader can be tested on
/// archives made to order: stored or deflated, with or without ZIP64.
enum TestZip {
    struct File {
        var path: String
        var data: Data
        var deflated = false

        init(_ path: String, _ data: Data, deflated: Bool = false) {
            self.path = path
            self.data = data
            self.deflated = deflated
        }

        init(_ path: String, _ text: String, deflated: Bool = false) {
            self.init(path, Data(text.utf8), deflated: deflated)
        }
    }

    /// An archive of `files`. With `zip64`, every size and offset is written
    /// in ZIP64's records, as tools do for archives past 4 GB.
    static func archive(_ files: [File], zip64: Bool = false) throws -> Data {
        var output = Data()
        var central = Data()
        for file in files {
            let contents = file.deflated ? try (file.data as NSData).compressed(using: .zlib) as Data : file.data
            let name = Data(file.path.utf8)
            let crc = CRC32.checksum(file.data)
            let offset = UInt64(output.count)
            let method: UInt16 = file.deflated ? 8 : 0

            var localExtra = Data()
            if zip64 {
                localExtra.append(le: UInt16(1)); localExtra.append(le: UInt16(16))
                localExtra.append(le: UInt64(file.data.count)); localExtra.append(le: UInt64(contents.count))
            }
            output.append(le: UInt32(0x0403_4B50))
            output.append(le: UInt16(zip64 ? 45 : 20)); output.append(le: UInt16(0x0800)); output.append(le: method)
            output.append(le: UInt32(0)) // time and date
            output.append(le: crc)
            output.append(le: zip64 ? UInt32.max : UInt32(contents.count))
            output.append(le: zip64 ? UInt32.max : UInt32(file.data.count))
            output.append(le: UInt16(name.count)); output.append(le: UInt16(localExtra.count))
            output.append(name); output.append(localExtra)
            output.append(contents)

            var centralExtra = Data()
            if zip64 {
                centralExtra.append(le: UInt16(1)); centralExtra.append(le: UInt16(24))
                centralExtra.append(le: UInt64(file.data.count)); centralExtra.append(le: UInt64(contents.count))
                centralExtra.append(le: offset)
            }
            central.append(le: UInt32(0x0201_4B50))
            central.append(le: UInt16(0x031E)); central.append(le: UInt16(zip64 ? 45 : 20))
            central.append(le: UInt16(0x0800)); central.append(le: method)
            central.append(le: UInt32(0))
            central.append(le: crc)
            central.append(le: zip64 ? UInt32.max : UInt32(contents.count))
            central.append(le: zip64 ? UInt32.max : UInt32(file.data.count))
            central.append(le: UInt16(name.count)); central.append(le: UInt16(centralExtra.count))
            central.append(le: UInt16(0)) // comment
            central.append(le: UInt16(0)); central.append(le: UInt16(0)); central.append(le: UInt32(0))
            central.append(le: zip64 ? UInt32.max : UInt32(offset))
            central.append(name); central.append(centralExtra)
        }
        let directoryOffset = UInt64(output.count)
        output.append(central)
        if zip64 {
            let zip64EndOffset = UInt64(output.count)
            output.append(le: UInt32(0x0606_4B50)); output.append(le: UInt64(44))
            output.append(le: UInt16(45)); output.append(le: UInt16(45))
            output.append(le: UInt32(0)); output.append(le: UInt32(0))
            output.append(le: UInt64(files.count)); output.append(le: UInt64(files.count))
            output.append(le: UInt64(central.count)); output.append(le: directoryOffset)
            output.append(le: UInt32(0x0706_4B50)); output.append(le: UInt32(0))
            output.append(le: zip64EndOffset); output.append(le: UInt32(1))
        }
        output.append(le: UInt32(0x0605_4B50))
        output.append(le: UInt16(0)); output.append(le: UInt16(0))
        output.append(le: zip64 ? UInt16.max : UInt16(files.count))
        output.append(le: zip64 ? UInt16.max : UInt16(files.count))
        output.append(le: zip64 ? UInt32.max : UInt32(central.count))
        output.append(le: zip64 ? UInt32.max : UInt32(directoryOffset))
        output.append(le: UInt16(0))
        return output
    }

    /// A new, empty folder for a test, removed by the caller.
    static func temporaryFolder() throws -> URL {
        let folder = URL.temporaryDirectory.appending(path: "ZipTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Writes an archive of `files` into `folder` as `name`.
    static func write(_ files: [File], named name: String, in folder: URL, zip64: Bool = false) throws -> URL {
        let url = folder.appending(path: name)
        try archive(files, zip64: zip64).write(to: url)
        return url
    }
}

extension Data {
    mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
