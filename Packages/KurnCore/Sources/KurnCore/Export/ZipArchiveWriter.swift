//
//  ZipArchiveWriter.swift
//  KurnCore
//
//  The smallest ZIP writer a Word document needs: entries are *stored*
//  (method 0, no compression), so the format reduces to headers, CRC-32 and
//  the bytes themselves — no compression library, no dependency, and the
//  output is byte-for-byte deterministic for the same input.
//
//  Storing is a deliberate trade: a meeting's .docx is a few hundred KB of
//  XML at most, and every Office Open XML consumer accepts stored entries.
//  ZIP64 is not supported; an archive is refused well before its 4 GB limit.
//

import Foundation

public struct ZipArchiveWriter {
    public enum WriterError: Error, Equatable {
        case entryTooLarge(String)
        case tooManyEntries
    }

    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries: [Entry] = []

    public init() {}

    /// Appends a file at `path` (forward slashes, no leading slash).
    public mutating func add(path: String, contents: Data) throws {
        guard contents.count < Int(UInt32.max), data.count + contents.count < Int(UInt32.max) else {
            throw WriterError.entryTooLarge(path)
        }
        guard entries.count < Int(UInt16.max) else { throw WriterError.tooManyEntries }
        let name = Array(path.utf8)
        let entry = Entry(
            name: name,
            crc: CRC32.checksum(contents),
            size: UInt32(contents.count),
            offset: UInt32(data.count)
        )
        data.append(le32: 0x0403_4B50)       // local file header signature
        data.append(le16: 20)                // version needed to extract
        data.append(le16: Self.flags)
        data.append(le16: 0)                 // method: stored
        data.append(le16: Self.dosTime)
        data.append(le16: Self.dosDate)
        data.append(le32: entry.crc)
        data.append(le32: entry.size)        // compressed size
        data.append(le32: entry.size)        // uncompressed size
        data.append(le16: UInt16(name.count))
        data.append(le16: 0)                 // extra field length
        data.append(contentsOf: name)
        data.append(contents)
        entries.append(entry)
    }

    public mutating func add(path: String, text: String) throws {
        try add(path: path, contents: Data(text.utf8))
    }

    /// The finished archive: every entry, then the central directory.
    public func finalized() -> Data {
        var out = data
        let directoryOffset = UInt32(out.count)
        for entry in entries {
            out.append(le32: 0x0201_4B50)    // central directory header signature
            out.append(le16: 20)             // version made by
            out.append(le16: 20)             // version needed to extract
            out.append(le16: Self.flags)
            out.append(le16: 0)              // method: stored
            out.append(le16: Self.dosTime)
            out.append(le16: Self.dosDate)
            out.append(le32: entry.crc)
            out.append(le32: entry.size)
            out.append(le32: entry.size)
            out.append(le16: UInt16(entry.name.count))
            out.append(le16: 0)              // extra field length
            out.append(le16: 0)              // comment length
            out.append(le16: 0)              // disk number start
            out.append(le16: 0)              // internal attributes
            out.append(le32: 0)              // external attributes
            out.append(le32: entry.offset)
            out.append(contentsOf: entry.name)
        }
        let directorySize = UInt32(out.count) - directoryOffset
        out.append(le32: 0x0605_4B50)        // end of central directory signature
        out.append(le16: 0)                  // this disk
        out.append(le16: 0)                  // disk with the central directory
        out.append(le16: UInt16(entries.count))
        out.append(le16: UInt16(entries.count))
        out.append(le32: directorySize)
        out.append(le32: directoryOffset)
        out.append(le16: 0)                  // comment length
        return out
    }

    /// Bit 11: names are UTF-8.
    private static let flags: UInt16 = 1 << 11
    /// 1980-01-01 00:00, the DOS epoch. A fixed stamp keeps the output
    /// deterministic; nothing reads it back.
    private static let dosTime: UInt16 = 0
    private static let dosDate: UInt16 = (0 << 9) | (1 << 5) | 1
}

public enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }

    public static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(le16 value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8(value >> 8))
    }

    mutating func append(le32 value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8(value >> 24))
    }
}
