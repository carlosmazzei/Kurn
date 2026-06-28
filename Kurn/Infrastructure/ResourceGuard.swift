//
//  ResourceGuard.swift
//  Kurn
//
//  Centralized guardrails for disk and memory pressure. The OS can still kill a
//  process that spikes too quickly, but these checks fail before expensive model
//  loads / audio renders when the device is already in a risky state.
//

import Foundation

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
            .first ?? FileManager.default.temporaryDirectory
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
            AppLog.transcription.atError.error("resource: storage check failed: \(error.localizedDescription, privacy: .public)")
        }
        return nil
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
