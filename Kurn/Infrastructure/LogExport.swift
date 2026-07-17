//
//  LogExport.swift
//  Kurn
//
//  Exports the app's own recent log history (already flowing through AppLog /
//  os.Logger) to a shareable text file, for support/bug-report purposes.
//
//  `OSLogStore(scope: .currentProcessIdentifier)` can only read the *calling
//  process's own* persisted unified-log entries, with no special entitlement
//  required — that's exactly the mechanism this needs, and why this can't
//  (and doesn't try to) export KurnWatch's logs, which live in a different
//  process. Note `OSLogStore.local()` (the macOS-only entry point) is
//  unavailable on iOS; the `scope:` initializer is the iOS-compatible one.
//

import Foundation
import os
import OSLog

/// A plain snapshot of one log entry, decoupled from `OSLogEntryLog` (an
/// OS-constructed type with no public initializer, and not audited as
/// `Sendable` in a way that's safe to store directly in a `Sendable` struct)
/// so formatting logic can be unit-tested with synthetic data instead of a
/// live `OSLogStore`. `level` is already resolved to a display string at
/// snapshot time, not kept as `OSLogEntryLog.Level`.
struct LogEntrySnapshot: Sendable {
    let date: Date
    let category: String
    let level: String
    let message: String
}

enum LogExport {
    /// Pure formatting: a short header followed by one line per entry,
    /// oldest first (matching the order `OSLogStore` yields them in).
    static func formatText(entries: [LogEntrySnapshot], generatedAt: Date) -> String {
        let formatter = ISO8601DateFormatter()
        var out = "# Kurn log export\n"
        out += "Generated: \(formatter.string(from: generatedAt))\n"
        out += "Entries: \(entries.count)\n\n"
        for entry in entries {
            out += "[\(formatter.string(from: entry.date))] [\(entry.category)] [\(entry.level)] \(entry.message)\n"
        }
        return out
    }

    private static func levelName(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "undefined"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "unknown"
        }
    }

    /// Read this process's own persisted log entries for `AppLog.subsystem`
    /// from the last `hoursBack` hours.
    static func fetchRecentEntries(hoursBack: Int = 24) throws -> [LogEntrySnapshot] {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let cutoff = Date().addingTimeInterval(-Double(hoursBack) * 3600)
        let position = store.position(date: cutoff)
        let predicate = NSPredicate(format: "subsystem == %@", AppLog.subsystem)
        return try store.getEntries(at: position, matching: predicate)
            .compactMap { $0 as? OSLogEntryLog }
            .map { entry in
                LogEntrySnapshot(
                    date: entry.date,
                    category: entry.category,
                    level: levelName(entry.level),
                    message: entry.composedMessage
                )
            }
    }

    /// Fetch, format, and write the result to a shareable temp file via the
    /// same pipeline `MeetingExport` uses (own UUID-named subdirectory,
    /// `RecordingProtection` applied, cleaned up by `ActivityView` once shared).
    static func temporaryFile(hoursBack: Int = 24) throws -> URL {
        let entries = try fetchRecentEntries(hoursBack: hoursBack)
        let text = formatText(entries: entries, generatedAt: Date())
        return try MeetingExport.temporaryFile(markdown: text, suggestedName: "kurn-logs-\(Date().timeIntervalSince1970)")
    }
}
