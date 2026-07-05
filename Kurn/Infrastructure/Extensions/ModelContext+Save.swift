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

extension ModelContext {
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
