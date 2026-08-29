//
//  ModelContext+Save.swift
//  Kurn
//
//  Shared "save and surface the failure" helper. User-initiated mutations used to
//  persist with `try? modelContext.save()`, silently dropping any error and leaving
//  the in-memory models and the on-disk store diverged. This centralizes the
//  save + log + `AppError` mapping so call sites can present the failure with
//  `.errorAlert` instead of swallowing it.
//

import SwiftData
import KurnCore

/// The one operation reliability-track call sites need from a `ModelContext`:
/// save, with failure reported rather than thrown/dropped. A full fake (one
/// that can also stand in for `fetch`) is deliberately not built yet — several
/// call sites, `RecordingRecovery` included, fetch and save on the same
/// concrete context in one function, and splitting that into separately
/// injected read/write dependencies is a real architectural change, not a
/// seam. That split belongs to the durability-core phase, when
/// `RecordingRecovery` is restructured for the operation journal anyway.
///
/// Deliberately not `@MainActor`: `RecordingRecovery.recoverOrphans` builds a
/// background `ModelContext(modelContainer)` (not `.mainContext`) and calls
/// `save()` from a plain, non-async static function — matching `ModelContext`
/// itself, which is not statically actor-isolated.
protocol ModelPersisting {
    @discardableResult
    func saveOrError() -> AppError?
}

extension ModelContext: ModelPersisting {
    /// Save pending changes, returning an already-logged `AppError` on failure
    /// (instead of silently dropping it) so the caller can surface it. Returns
    /// `nil` on success.
    @discardableResult
    func saveOrError() -> AppError? {
        do {
            try save()
            return nil
        } catch {
            AppLog.persistence.atError.error("Failed to save context: \(error.localizedDescription, privacy: .public)")
            return .persistenceFailed(error.localizedDescription)
        }
    }
}
