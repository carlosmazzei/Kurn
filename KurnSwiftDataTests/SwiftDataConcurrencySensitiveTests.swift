//
//  SwiftDataConcurrencySensitiveTests.swift
//  KurnSwiftDataTests
//
//  Purely organizational: an empty parent suite that exists only so its
//  `.serialized` trait recursively applies to every nested suite below it
//  (Swift Testing's documented behavior — a suite trait is inherited by
//  contained sub-suites, unlike two independent top-level `@Suite(.serialized)`
//  types, which still run concurrently *with each other*).
//
//  Kept as defence in depth, not as a fix for anything currently known to
//  be broken. Every test below opens a real `ModelContainer`, and a
//  container's lifetime is process-wide state; serializing them keeps that
//  churn from overlapping, which makes any future failure here reproducible
//  and attributable instead of order-dependent.
//
//  Historical note, because it cost several days. CI repeatedly crashed
//  here with:
//
//    SwiftData/BackingData.swift:844: Fatal error: This model instance was
//    destroyed by calling ModelContext.reset and is no longer usable.
//
//  That was long misread as a known, radar-tracked SwiftData concurrency
//  issue (FB14089213-class) — the signature matches, and Swift Testing runs
//  the whole suite in one process by default. It was not. The actual cause
//  was an ordinary use-after-free in production code: `ModelStoreSalvage`
//  returned `Meeting`s fetched from a `ModelContainer` held in a local, so
//  the container deallocated (resetting its `mainContext`, destroying every
//  instance in it) before the caller read a single property. See
//  `ModelStoreSalvage.recoverReadOnly`.
//
//  The lesson worth keeping: a crash that reproduces deterministically in
//  isolation is not a race, however much its message sounds like one.
//
import Testing

@Suite(.serialized)
enum SwiftDataConcurrencySensitiveTests {}
