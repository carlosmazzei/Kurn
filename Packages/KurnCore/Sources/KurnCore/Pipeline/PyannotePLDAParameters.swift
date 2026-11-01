import Foundation

public enum PyannotePLDAParameters {
    public enum Failure: Error, Sendable, Equatable {
        case invalidDocument
        case invalidTensor
        case nonFiniteValue
    }

    public static let dimension = 128

    public static func decodePsi(_ data: Data) throws -> [Double] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tensors = root["tensors"] as? [String: Any],
              let psi = tensors["psi"] as? [String: Any],
              let base64 = psi["data_base64"] as? String else { throw Failure.invalidDocument }
        guard let bytes = Data(base64Encoded: base64), bytes.count == dimension * MemoryLayout<UInt32>.size else {
            throw Failure.invalidTensor
        }
        let values = bytes.withUnsafeBytes { buffer in
            (0..<dimension).map { index in
                let bits = buffer.loadUnaligned(fromByteOffset: index * MemoryLayout<UInt32>.size, as: UInt32.self)
                return Double(Float(bitPattern: UInt32(littleEndian: bits)))
            }
        }
        guard values.allSatisfy(\.isFinite) else { throw Failure.nonFiniteValue }
        return values
    }
}
