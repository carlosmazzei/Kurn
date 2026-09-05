//
//  ProviderCircuitBreaker.swift
//  Kurn
//

import Foundation
import KurnCore

enum ProviderAutomationTrigger: Equatable, Sendable {
    case automatic
    case explicit
}

enum ProviderCircuitFailure: Equatable, Sendable {
    case transient
    case ambiguous
    case configuration

    init(error: Error) {
        guard let error = error as? AppError else {
            self = .transient
            return
        }
        switch error {
        case .ambiguousProviderResult:
            self = .ambiguous
        case .noAPIKey, .invalidProviderURL, .providerResponseTooLarge,
             .decodingError, .summaryTruncated, .generationTruncated:
            self = .configuration
        case .apiError(let status, _):
            self = [400, 401, 403, 404, 422].contains(status) ? .configuration : .transient
        default:
            self = .transient
        }
    }
}

struct ProviderCircuitRecord: Codable, Equatable, Sendable {
    var consecutiveFailures: Int
    var blockedUntil: Date?
    var requiresExplicitRetry: Bool
}

protocol ProviderCircuitStateStoring: Sendable {
    func load() throws -> [String: ProviderCircuitRecord]
    func save(_ records: [String: ProviderCircuitRecord]) throws
}

final class UserDefaultsProviderCircuitStore: ProviderCircuitStateStoring, @unchecked Sendable {
    private static let key = "providerCircuit.records.v1"
    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() throws -> [String: ProviderCircuitRecord] {
        try lock.withLock {
            guard let data = defaults.data(forKey: Self.key) else { return [:] }
            return try JSONDecoder().decode([String: ProviderCircuitRecord].self, from: data)
        }
    }

    func save(_ records: [String: ProviderCircuitRecord]) throws {
        try lock.withLock {
            let data = try JSONEncoder().encode(records)
            defaults.set(data, forKey: Self.key)
        }
    }
}

actor ProviderCircuitBreaker {
    static let shared = ProviderCircuitBreaker()
    static let transientDelays: [TimeInterval] = [300, 1_800, 7_200, 86_400]
    static let ambiguousDelay: TimeInterval = 86_400

    private let store: any ProviderCircuitStateStoring
    private let now: @Sendable () -> Date
    private var records: [String: ProviderCircuitRecord]
    private var storageHealthy: Bool

    init(
        store: any ProviderCircuitStateStoring = UserDefaultsProviderCircuitStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
        do {
            records = try store.load()
            storageHealthy = true
        } catch {
            records = [:]
            storageHealthy = false
            AppLog.persistence.atError.error("providerCircuit: state unreadable; automatic work disabled")
        }
    }

    func allows(providerID: String, trigger: ProviderAutomationTrigger) -> Bool {
        if trigger == .explicit { return true }
        guard storageHealthy else { return false }
        guard let record = records[providerID] else { return true }
        if record.requiresExplicitRetry { return false }
        guard let blockedUntil = record.blockedUntil else { return true }
        return blockedUntil <= now()
    }

    func recordSuccess(providerID: String) {
        let wasOpen = records.removeValue(forKey: providerID) != nil
        if wasOpen {
            report(providerID: providerID, outcome: .succeeded, code: "circuit_closed")
        }
        if wasOpen || !storageHealthy { persist() }
    }

    func recordFailure(providerID: String, failure: ProviderCircuitFailure) {
        let previousFailures = records[providerID]?.consecutiveFailures ?? 0
        let failures = min(previousFailures + 1, Self.transientDelays.count)
        let record: ProviderCircuitRecord
        switch failure {
        case .configuration:
            record = ProviderCircuitRecord(
                consecutiveFailures: failures,
                blockedUntil: nil,
                requiresExplicitRetry: true
            )
        case .ambiguous:
            record = ProviderCircuitRecord(
                consecutiveFailures: failures,
                blockedUntil: now().addingTimeInterval(Self.ambiguousDelay),
                requiresExplicitRetry: true
            )
        case .transient:
            record = ProviderCircuitRecord(
                consecutiveFailures: failures,
                blockedUntil: now().addingTimeInterval(Self.transientDelays[failures - 1]),
                requiresExplicitRetry: false
            )
        }
        records[providerID] = record
        report(providerID: providerID, outcome: .failed, attempt: failures, code: "circuit_open_\(failure)")
        persist()
    }

    func record(for providerID: String) -> ProviderCircuitRecord? {
        records[providerID]
    }

    /// Clears any open circuit for `providerID`. A `.configuration` (or
    /// `.ambiguous`) failure sets `requiresExplicitRetry`, which `allows`
    /// honors forever regardless of `blockedUntil` — the only way out is an
    /// explicit trigger that happens to succeed, and until now the only one
    /// wired up was `WikiCoordinator.rebuildWiki()`. Automatic AI title
    /// generation has no explicit path at all, so fixing the underlying
    /// problem (a bad key, a wrong base URL) left it silently blocked
    /// forever. Called when the user edits that provider's config, since
    /// that is exactly the kind of change that could resolve a
    /// configuration failure.
    func reset(providerID: String) {
        guard records.removeValue(forKey: providerID) != nil else { return }
        persist()
    }

    private func persist() {
        do {
            try store.save(records)
            storageHealthy = true
        } catch {
            storageHealthy = false
            AppLog.persistence.atError.error("providerCircuit: state save failed; automatic work disabled")
            report(providerID: "", outcome: .failed, code: "circuit_state_unwritable")
        }
    }

    /// `providerID` is a provider enum's raw value, never user content.
    private func report(providerID: String, outcome: ReliabilityEvent.Outcome, attempt: Int = 0, code: String) {
        ReliabilityLog.record(ReliabilityEvent(
            operationID: OperationID(providerID.isEmpty ? "circuit" : providerID),
            operation: "provider_circuit",
            stage: providerID,
            outcome: outcome,
            attempt: attempt,
            code: code
        ))
    }
}
