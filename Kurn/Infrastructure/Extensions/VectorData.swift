//
//  VectorData.swift
//  Kurn
//
//  Compact `[Float]` <-> `Data` conversion for embedding vectors persisted on
//  `SemanticChunk`. Vectors are stored as raw little-endian `Float32` bytes
//  rather than JSON: a 512-dim vector is 2 KB of `Data` instead of a multi-KB
//  JSON array of decimal strings, and decoding is a straight `memcpy`. The bytes
//  live inside the SwiftData store, so they inherit its file protection.
//

import Foundation

enum VectorData {
    /// Encode a vector as little-endian `Float32` bytes. Stored on-device only,
    /// so a fixed little-endian layout is safe (every Apple target is
    /// little-endian) and keeps the encoding independent of host byte order.
    static func encode(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * MemoryLayout<Float32>.size)
        for value in vector {
            var little = Float32(value).bitPattern.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Decode little-endian `Float32` bytes back into a vector. Returns an empty
    /// array when the byte count isn't a whole number of `Float32`s, so a
    /// corrupt/legacy blob degrades to "no match" rather than crashing.
    static func decode(_ data: Data) -> [Float] {
        let stride = MemoryLayout<Float32>.size
        guard data.count % stride == 0 else { return [] }
        var result = [Float]()
        result.reserveCapacity(data.count / stride)
        var index = data.startIndex
        while index < data.endIndex {
            var bits: UInt32 = 0
            for offset in 0..<stride {
                bits |= UInt32(data[index + offset]) << (8 * offset)
            }
            result.append(Float(bitPattern: UInt32(littleEndian: bits)))
            index += stride
        }
        return result
    }
}
