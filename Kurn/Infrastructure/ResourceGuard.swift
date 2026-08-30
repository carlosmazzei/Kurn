//
//  ResourceGuard.swift
//  Kurn
//
//  Centralized guardrails for disk and memory pressure. The OS can still kill a
//  process that spikes too quickly, but these checks fail before expensive model
//  loads / audio renders when the device is already in a risky state.
//

import Foundation
import KurnCore

#if canImport(UIKit)
import UIKit
#endif

enum ResourceGuard {
    static let minimumFreeStorageForTranscription: Int64 = 750 * 1_024 * 1_024
    static let minimumFreeStorageForModelDownload: Int64 = 2_500 * 1_024 * 1_024

    static func requireTranscriptionHeadroom() async throws {
        try await requireHealthyResources(minimumFreeStorage: minimumFreeStorageForTranscription)
    }

    static func requireModelDownloadHeadroom() async throws {
        try await requireHealthyResources(minimumFreeStorage: minimumFreeStorageForModelDownload)
    }

    static func requireHealthyResources(minimumFreeStorage: Int64) async throws {
        // Several best-effort audio engines intentionally convert their own
        // errors into usable fallback output. Cancellation is different: once
        // the user taps Stop, every boundary between pipeline stages must abort
        // even if the preceding engine swallowed `CancellationError`.
        try Task.checkCancellation()
        try await requireNoMemoryPressure()
        try requireFreeStorage(atLeast: minimumFreeStorage)
    }

    static func requireNoMemoryPressure() async throws {
        #if canImport(UIKit)
        if await ResourcePressureMonitor.shared.didReceiveMemoryWarning {
            throw AppError.resourceUnavailable(
                NSLocalizedString("error.resource_memory_pressure", comment: "Low memory")
            )
        }
        #endif
    }

    static func requireFreeStorage(atLeast requiredBytes: Int64) throws {
        guard let available = availableStorageBytes() else { return }
        guard available >= requiredBytes else {
            throw AppError.resourceUnavailable(
                String(
                    format: NSLocalizedString("error.resource_low_storage", comment: "Low storage"),
                    ByteCountFormatter.string(fromByteCount: requiredBytes, countStyle: .file),
                    ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
                )
            )
        }
    }

    static func availableStorageBytes(
        at url: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory,
        logFailure: Bool = true
    ) -> Int64? {
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey
            ])
            if let important = values.volumeAvailableCapacityForImportantUsage {
                return important
            }
            if let capacity = values.volumeAvailableCapacity {
                return Int64(capacity)
            }
        } catch {
            if logFailure {
                AppLog.transcription.atError.error("resource: storage capacity query failed")
            }
        }
        return nil
    }

    /// Throws the wrapped `AppError` when `error` is a resource-pressure
    /// failure; otherwise returns normally so the caller applies its own
    /// fallback/rethrow behavior.
    static func rethrowIfResourceFailure(_ error: Error) throws {
        if let appError = appErrorIfResourceFailure(error) { throw appError }
    }

    static func appErrorIfResourceFailure(_ error: Error) -> AppError? {
        if let appError = error as? AppError { return appError }

        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           nsError.code == CocoaError.Code.fileWriteOutOfSpace.rawValue {
            return AppError.resourceUnavailable(
                NSLocalizedString("error.resource_disk_full", comment: "Disk full")
            )
        }

        let message = nsError.localizedDescription.lowercased()
        if message.contains("no space") || message.contains("not enough space") || message.contains("disk full") {
            return AppError.resourceUnavailable(
                NSLocalizedString("error.resource_disk_full", comment: "Disk full")
            )
        }

        return nil
    }
}

enum RecordingStorageCapacity: Equatable, Sendable {
    case available(Int64)
    case unknown
}

protocol RecordingStorageProbing: Sendable {
    func capacity(at url: URL) -> RecordingStorageCapacity
    func fileSize(at url: URL) -> Int64?
}

struct SystemRecordingStorageProbe: RecordingStorageProbing {
    func capacity(at url: URL) -> RecordingStorageCapacity {
        guard let bytes = ResourceGuard.availableStorageBytes(at: url, logFailure: false) else { return .unknown }
        return .available(bytes)
    }

    func fileSize(at url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }
}

enum RecordingStorageRateBasis: Equatable, Sendable {
    case configured
    case measured
}

struct RecordingStorageEstimate: Equatable, Sendable {
    let availableBytes: Int64
    let runway: TimeInterval
    let bytesPerSecond: Double
    let rateBasis: RecordingStorageRateBasis
}

enum RecordingStorageState: Equatable, Sendable {
    case unknown
    case sufficient(RecordingStorageEstimate)
    case low(RecordingStorageEstimate)

    var estimate: RecordingStorageEstimate? {
        switch self {
        case .unknown: return nil
        case .sufficient(let estimate), .low(let estimate): return estimate
        }
    }

    var userMessage: String? {
        switch self {
        case .unknown:
            return NSLocalizedString(
                "recorder.storage_unknown",
                comment: "Available recording storage could not be checked"
            )
        case .low(let estimate):
            return String(
                format: NSLocalizedString(
                    "recorder.storage_low",
                    comment: "Estimated recording time remaining"
                ),
                estimate.runway.clockDisplay
            )
        case .sufficient:
            return nil
        }
    }
}

struct RecordingStorageMonitor: Sendable {
    static let safetyReserveBytes: Int64 = 10 * 1_024 * 1_024
    static let minimumStartRunway: TimeInterval = 30 * 60
    static let lowRunway: TimeInterval = 5 * 60
    static let minimumMeasurementDuration: TimeInterval = 10
    static let outputSampleRate: Double = 24_000

    let configuredBytesPerSecond: Double

    init(bitRate: Int) {
        configuredBytesPerSecond = max(1, Double(bitRate) / 8 * 1.1)
    }

    var requiredStartBytes: Int64 {
        Self.safetyReserveBytes
            + Int64(ceil(configuredBytesPerSecond * Self.minimumStartRunway))
    }

    func assess(
        capacity: RecordingStorageCapacity,
        fileSize: Int64?,
        writtenOutputFrames: Int64
    ) -> RecordingStorageState {
        guard case .available(let availableBytes) = capacity else { return .unknown }
        let rate = byteRate(fileSize: fileSize, writtenOutputFrames: writtenOutputFrames)
        let usableBytes = max(0, availableBytes - Self.safetyReserveBytes)
        let estimate = RecordingStorageEstimate(
            availableBytes: availableBytes,
            runway: Double(usableBytes) / rate.bytesPerSecond,
            bytesPerSecond: rate.bytesPerSecond,
            rateBasis: rate.basis
        )
        return estimate.runway <= Self.lowRunway ? .low(estimate) : .sufficient(estimate)
    }

    func startError(for state: RecordingStorageState) -> AppError? {
        guard let estimate = state.estimate,
              estimate.runway < Self.minimumStartRunway else { return nil }
        return .resourceUnavailable(String(
            format: NSLocalizedString("error.resource_low_storage", comment: "Low storage"),
            ByteCountFormatter.string(fromByteCount: requiredStartBytes, countStyle: .file),
            ByteCountFormatter.string(fromByteCount: estimate.availableBytes, countStyle: .file)
        ))
    }

    private func byteRate(
        fileSize: Int64?,
        writtenOutputFrames: Int64
    ) -> (bytesPerSecond: Double, basis: RecordingStorageRateBasis) {
        let duration = Double(writtenOutputFrames) / Self.outputSampleRate
        guard duration >= Self.minimumMeasurementDuration,
              let fileSize,
              fileSize > 0 else {
            return (configuredBytesPerSecond, .configured)
        }
        let measured = Double(fileSize) / duration
        guard measured.isFinite, measured > configuredBytesPerSecond else {
            return (configuredBytesPerSecond, .configured)
        }
        return (measured, .measured)
    }
}

#if canImport(UIKit)
@MainActor
final class ResourcePressureMonitor {
    static let shared = ResourcePressureMonitor()

    private(set) var didReceiveMemoryWarning = false
    private var observer: NSObjectProtocol?

    private init() {}

    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.didReceiveMemoryWarning = true
                AppLog.transcription.atError.error("resource: received memory warning")
            }
        }
    }

    func resetMemoryWarning() {
        didReceiveMemoryWarning = false
    }

    #if DEBUG
    func markMemoryWarningForTesting() {
        didReceiveMemoryWarning = true
    }
    #endif
}
#endif
