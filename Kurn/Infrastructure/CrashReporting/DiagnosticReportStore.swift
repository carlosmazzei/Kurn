//
//  DiagnosticReportStore.swift
//  Kurn
//
//  On-disk storage for formatted MetricKit diagnostic reports. Mirrors
//  RecordingProtection's directory-protection shape: a dedicated,
//  completeUnlessOpen-protected directory under Application Support, since
//  these are diagnostic data rather than user media (which lives under
//  Documents/Recordings).
//

import Foundation

struct DiagnosticReportEntry: Identifiable, Equatable {
    let id: String
    let url: URL
    let kind: DiagnosticReportFormatter.Kind
    let receivedAt: Date
}

enum DiagnosticReportStore {
    static let directoryName = "DiagnosticReports"

    /// Most-recent reports kept on disk; older ones are pruned on every save.
    static let retentionLimit = 20

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
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

    @discardableResult
    static func save(_ text: String, kind: DiagnosticReportFormatter.Kind, receivedAt: Date) throws -> URL {
        let directory = try directory()
        let name = "\(kind.rawValue)-\(dateFormatter.string(from: receivedAt))-\(UUID().uuidString.prefix(8)).txt"
        let url = directory.appendingPathComponent(name)
        try text.data(using: .utf8)?.write(to: url, options: .atomic)
        RecordingProtection.apply(to: url)
        prune()
        return url
    }

    static func list() -> [DiagnosticReportEntry] {
        guard let directory = try? directory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return urls.compactMap(entry(from:)).sorted { $0.receivedAt > $1.receivedAt }
    }

    static func delete(_ entry: DiagnosticReportEntry) {
        try? FileManager.default.removeItem(at: entry.url)
    }

    /// Parse `<kind>-<yyyyMMddTHHmmss>-<uuid prefix>.txt` back into an entry.
    private static func entry(from url: URL) -> DiagnosticReportEntry? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-", maxSplits: 1)
        guard parts.count == 2,
              let kind = DiagnosticReportFormatter.Kind(rawValue: String(parts[0])) else { return nil }
        let dateAndSuffix = parts[1].split(separator: "-", maxSplits: 1)
        guard let dateAndSuffix = dateAndSuffix.first,
              let date = dateFormatter.date(from: String(dateAndSuffix)) else { return nil }
        return DiagnosticReportEntry(id: name, url: url, kind: kind, receivedAt: date)
    }

    /// Pure selection of which URLs to delete to keep only the `keeping` most
    /// recent — unit-testable without touching disk.
    static func urlsToDelete(from entries: [(url: URL, date: Date)], keeping: Int) -> [URL] {
        guard entries.count > keeping else { return [] }
        let sorted = entries.sorted { $0.date > $1.date }
        return sorted.dropFirst(keeping).map(\.url)
    }

    private static func prune() {
        let entries = list().map { (url: $0.url, date: $0.receivedAt) }
        for url in urlsToDelete(from: entries, keeping: retentionLimit) {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
