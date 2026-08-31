//
//  SwiftDataConcurrencySensitiveTests.swift
//  KurnTests
//
//  Purely organizational: an empty parent suite that exists only so its
//  `.serialized` trait recursively applies to every nested suite below it
//  (Swift Testing's documented behavior — a suite trait is inherited by
//  contained sub-suites, unlike two independent top-level `@Suite(.serialized)`
//  types, which still run concurrently *with each other*).
//
//  CI hit an intermittent SwiftData crash multiple times while H2 PR 4's new
//  tests ran (docs/resilience-megaplan.md):
//
//    SwiftData/BackingData.swift:844: Fatal error: This model instance was
//    destroyed by calling ModelContext.reset and is no longer usable.
//
//  This is a known SwiftData issue (radar-tracked, e.g. FB14089213 and
//  Apple Developer Forums thread 757521): a `ModelContainer`'s asynchronous
//  background housekeeping can still be in flight when the container/context
//  that owns it is deallocated, and touching the resulting stale backing
//  data crashes the whole process rather than throwing. It is not specific
//  to this app's code — some crash instances on this PR occurred nowhere
//  near a Kurn file, in pre-existing, unrelated tests — but Swift Testing
//  runs the entire suite in one process by default, so more `ModelContainer`
//  churn (this PR added several) makes the race more likely to trip within
//  any given run. Nesting every SwiftData-touching test this PR adds under
//  this one serialized root at least removes their mutual concurrency as a
//  contributor. It does not, and cannot by itself, fix the underlying
//  framework issue across the rest of the suite.
//
import Testing

@Suite(.serialized)
enum SwiftDataConcurrencySensitiveTests {}
