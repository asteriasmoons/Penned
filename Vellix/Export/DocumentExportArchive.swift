import Foundation

// A stored ZIP archive: valid ZIP/OOXML/TextPack without an external executable.
enum DocumentExportArchive {
    struct Entry {
        let name: String
        let data: Data?
        let file: URL?
        init(_ name: String, data: Data) { self.name = name; self.data = data; file = nil }
        init(_ name: String, file: URL) { self.name = name; self.file = file; data = nil }
    }
    private struct Central { let name: Data; let crc: UInt32; let size: UInt32; let offset: UInt32 }
    private static let table: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 1 ? 0xedb88320 ^ (crc >> 1) : crc >> 1 }
        return crc
    }
    private static func crc(_ data: Data, starting: UInt32 = 0xffffffff) -> UInt32 {
        data.reduce(starting) { table[Int(($0 ^ UInt32($1)) & 255)] ^ ($0 >> 8) }
    }
    static func write(_ entries: [Entry], to url: URL) throws {
        guard entries.count <= Int(UInt16.max) else { throw DocumentExportError.failed("Too many files for this archive.") }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        var success = false
        defer { try? output.close(); if !success { try? FileManager.default.removeItem(at: url) } }
        var central: [Central] = []
        func append(_ value: UInt16) throws { var n = value.littleEndian; try withUnsafeBytes(of: &n) { try output.write(contentsOf: Data($0)) } }
        func append32(_ value: UInt32) throws { var n = value.littleEndian; try withUnsafeBytes(of: &n) { try output.write(contentsOf: Data($0)) } }
        for entry in entries {
            try Task.checkCancellation()
            guard !entry.name.hasPrefix("/"), !entry.name.split(separator: "/").contains("..") else { throw DocumentExportError.failed("Invalid export asset path.") }
            let name = Data(entry.name.utf8), offset = try output.offset()
            let size: UInt64
            if let data = entry.data { size = UInt64(data.count) }
            else if let file = entry.file { size = UInt64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            else { throw DocumentExportError.failed("An archive entry has no content.") }
            guard size < UInt64(UInt32.max), offset < UInt64(UInt32.max), name.count < Int(UInt16.max) else { throw DocumentExportError.failed("An export exceeds the ZIP file size limit.") }
            var checksum: UInt32 = 0xffffffff
            if let data = entry.data { checksum = crc(data) }
            else if let file = entry.file {
                let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { checksum = crc(chunk, starting: checksum) }
            }
            checksum ^= 0xffffffff
            try append32(0x04034b50); try append(20); try append(0x0800); try append(0); try append(0); try append(0x0021)
            try append32(checksum); try append32(UInt32(size)); try append32(UInt32(size)); try append(UInt16(name.count)); try append(0)
            try output.write(contentsOf: name)
            if let data = entry.data { try output.write(contentsOf: data) }
            else if let file = entry.file {
                let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: chunk) }
            }
            central.append(Central(name: name, crc: checksum, size: UInt32(size), offset: UInt32(offset)))
        }
        let start = try output.offset()
        for entry in central {
            try append32(0x02014b50); try append(20); try append(20); try append(0x0800); try append(0); try append(0); try append(0x0021)
            try append32(entry.crc); try append32(entry.size); try append32(entry.size); try append(UInt16(entry.name.count))
            try append(0); try append(0); try append(0); try append(0); try append32(0); try append32(entry.offset)
            try output.write(contentsOf: entry.name)
        }
        let end = try output.offset()
        guard end < UInt64(UInt32.max) else { throw DocumentExportError.failed("The export exceeds the ZIP file size limit.") }
        try append32(0x06054b50); try append(0); try append(0); try append(UInt16(central.count)); try append(UInt16(central.count))
        try append32(UInt32(end - start)); try append32(UInt32(start)); try append(0)
        try output.synchronize(); success = true
    }
}
