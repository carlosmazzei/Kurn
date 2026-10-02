//
//  AsyncTimeout.swift
//  KurnCore
//
//  Races an async operation against a deadline.
//
//  Only meaningful for an operation that actually suspends: a blocking call
//  with no suspension point cannot be abandoned by cancelling its task, so the
//  group would still wait for it (see `SherpaOnnxDiarizer`, which logs
//  slowness instead for exactly that reason).
//

import Foundation

/// Runs `operation`, throwing `timeoutError()` if it has not finished within
/// `seconds`. The loser is cancelled either way.
public func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    timeoutError: @escaping @Sendable () -> Error,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(max(0, seconds)))
            throw timeoutError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw CancellationError()
        }
        return result
    }
}
