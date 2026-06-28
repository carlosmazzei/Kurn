//
//  ResourceGuardTests.swift
//  KurnTests
//

import Foundation
import Testing
@testable import Kurn

struct ResourceGuardTests {

    @Test func hugeStorageRequirementThrowsResourceUnavailable() {
        guard ResourceGuard.availableStorageBytes() != nil else { return }

        do {
            try ResourceGuard.requireFreeStorage(atLeast: Int64.max)
            Issue.record("Expected resourceUnavailable for impossible storage requirement")
        } catch let error as AppError {
            guard case .resourceUnavailable = error else {
                Issue.record("Expected resourceUnavailable, got \(error)")
                return
            }
        } catch {
            Issue.record("Expected AppError, got \(error)")
        }
    }

    @Test func cocoaOutOfSpaceMapsToResourceUnavailable() throws {
        let error = NSError(
            domain: NSCocoaErrorDomain,
            code: CocoaError.Code.fileWriteOutOfSpace.rawValue
        )
        let appError = try #require(ResourceGuard.appErrorIfResourceFailure(error))
        guard case .resourceUnavailable = appError else {
            Issue.record("Expected resourceUnavailable, got \(appError)")
            return
        }
    }
}
