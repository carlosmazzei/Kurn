//
//  ReliabilityEventStore.swift
//  Kurn
//
//  H9 PR 22: a bounded, protected, on-device buffer of `ReliabilityEvent`s —
//  item 6's "keep the reliability event buffer local, encrypted and
//  bounded." Nothing here is transmitted automatically; the only way content
//  leaves the device is the explicit Share action in
//  `ReliabilityEventsListView`, matching `DiagnosticReportStore`'s existing
//  convention for MetricKit crash/hang reports.
//
//  Storage is one JSON-Lines file (append-only, one `ReliabilityEvent` per
//  line) rather than `DiagnosticReportStore`'s one-file-per-entry shape:
//  events are small structured facts, potentially many per operation, so a
//  single appendable file avoids one tiny file per event while still
//  supporting cheap `FileHandle` appends instead of rewriting the whole
//  buffer on every record. Directory protection mirrors
//  `DiagnosticReportStore`/`RecordingProtection`: `.completeUnlessOpen`
//  under Application Support, since these are diagnostic facts rather than
//  user media.
//

import Foundation
import KurnCore

enum ReliabilityEventStore {
    static let directoryName = "ReliabilityEvents"
    static let fileName = "events.jsonl"

    /// `ReliabilityLog.handler` is a plain synchronous `@Sendable` closure,
    /// callable from any isolation — `TranscriptionViewModel` calls it from
    /// the main actor, `DocumentGenerationService` from off it — so two
    /// events recorded around the same moment from different operations
    /// could otherwise interleave their writes to the same file or race a
    /// concurrent prune. An actor would serialize this naturally but would
    /// force every call site to `await`, which the handler's synchronous
    /// signature doesn't support; a lock keeps the API synchronous while
    /// still serializing the actual file access.
    private static let lock = NSLock()

    /// Most-recent events kept on disk; older ones are pruned once the
    /// buffer exceeds this by `pruneMargin`, so pruning isn't a full
    /// rewrite on every single append.
    static let maxEvents = 500
    /// How far past `maxEvents` the buffer is allowed to grow before a
    /// prune pass runs — not `private` so tests can derive an exact trigger
    /// count instead of hardcoding it.
    static let pruneMargin = 100

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static func directory() throws -> URL {
        let parent = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        let url = parent.appendingPathComponent(directoryName, isDirectory: true)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: RecordingProtection.protectionType]
            )
        }
        return url
    }

    private static func fileURL() throws -> URL {
        try directory().appendingPathComponent(fileName)
    }

    /// Append one event. Best-effort: a store failure here must never break
    /// the operation being reported on, so this only logs — matching
    /// `ReliabilityLog.handler`'s own os_log path, which keeps working even
    /// if this one fails.
    static func record(_ event: ReliabilityEvent) {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard let data = try? encoder.encode(event) else { return }
            let url = try fileURL()
            var line = data
            line.append(0x0A) // newline
            if let handle = FileHandle(forWritingAtPath: url.path) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
                RecordingProtection.apply(to: url)
            }
            pruneIfNeeded()
        } catch {
            AppLog.reliability.atError.error("ReliabilityEventStore: append failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Most recent events first.
    static func recentEvents(limit: Int = maxEvents) -> [ReliabilityEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? fileURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let events = decodeLines(text)
        return Array(events.reversed().prefix(limit))
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = try? fileURL() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Parses one `ReliabilityEvent` per non-empty line; a malformed line
    /// (e.g. a partial write interrupted mid-append) is skipped rather than
    /// failing the whole read.
    private static func decodeLines(_ text: String) -> [ReliabilityEvent] {
        text.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(ReliabilityEvent.self, from: data)
        }
    }

    private static func pruneIfNeeded() {
        guard let url = try? fileURL(),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > maxEvents + pruneMargin else { return }
        let kept = lines.suffix(maxEvents).joined(separator: "\n") + "\n"
        try? kept.data(using: .utf8)?.write(to: url, options: .atomic)
        RecordingProtection.apply(to: url)
    }
}
