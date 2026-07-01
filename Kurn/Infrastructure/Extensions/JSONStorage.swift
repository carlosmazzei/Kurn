//
//  JSONStorage.swift
//  Kurn
//
//  SwiftData can't persist arbitrary `Codable` arrays, so models store them as
//  JSON `Data` and expose them through computed properties. These helpers hold
//  the shared encode/decode boilerplate (with safe empty fallbacks) so each
//  model doesn't repeat it.
//

import Foundation

enum JSONStorage {
    /// Encode a value to JSON `Data`, falling back to empty `Data` on failure so
    /// a persisted property always has a concrete value.
    static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    /// Decode a JSON array from `Data`, falling back to an empty array on failure.
    static func decode<T: Decodable>(_ type: [T].Type, from data: Data) -> [T] {
        (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    /// Decode a single JSON value from `Data`, falling back to `nil` on failure.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(T.self, from: data)
    }
}
