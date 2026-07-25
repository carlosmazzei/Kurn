//
//  UserDefaults+Settings.swift
//  Kurn
//
//  Read helpers for the patterns `AppSettings.init` repeats for almost every
//  preference: restoring a `String`-backed enum, reading a `Bool` whose absent
//  value must default to `true`, and decoding a JSON-encoded value.
//
//  These are free functions on `UserDefaults` rather than members of
//  `AppSettings` so they can be called from its initializer before `self` is
//  fully initialized.
//

import Foundation

extension UserDefaults {
    /// Restore a `String`-backed enum, falling back when the key is absent or
    /// holds a raw value this build no longer defines (e.g. an engine removed
    /// in a later version).
    func enumValue<T: RawRepresentable>(forKey key: String, default fallback: T) -> T
    where T.RawValue == String {
        (string(forKey: key)).flatMap(T.init(rawValue:)) ?? fallback
    }

    /// Read a `Bool` with an explicit default for an absent key.
    ///
    /// `bool(forKey:)` returns `false` for a key that was never written, which
    /// is wrong for any preference that ships enabled — the user would silently
    /// get the opposite of the intended default on first launch. Going through
    /// `object(forKey:)` distinguishes "absent" from "explicitly false".
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }

    /// Decode a JSON-encoded value, returning `nil` when the key is absent or
    /// its contents no longer decode into `type` (a shape changed by an app
    /// update), so the caller can substitute its own default.
    func decoded<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
