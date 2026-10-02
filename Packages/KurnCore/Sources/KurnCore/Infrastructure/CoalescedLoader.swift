//
//  CoalescedLoader.swift
//  KurnCore
//
//  Load an expensive value once and share it: concurrent callers await the
//  same in-flight load instead of each starting their own, a success is kept
//  for every later caller, and a failure is not cached — the next call retries.
//  `FluidAudioModelStore` uses it for the shared Parakeet model, whose first
//  load compiles CoreML/ANE artifacts for tens of seconds.
//

import Foundation

public actor CoalescedLoader<Value: Sendable> {
    private var loaded: Value?
    private var inFlight: Task<Value, Error>?

    public init() {}

    /// The loaded value, or `nil` while nothing has loaded successfully.
    public var current: Value? { loaded }

    public func value(loadingWith load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        if let loaded { return loaded }
        if let inFlight { return try await inFlight.value }

        let task = Task { try await load() }
        inFlight = task
        do {
            let value = try await task.value
            loaded = value
            inFlight = nil
            return value
        } catch {
            inFlight = nil
            throw error
        }
    }
}
