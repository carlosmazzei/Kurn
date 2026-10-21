//
//  RecordingsDirectorySuite.swift
//  KurnTests
//
//  Serializes the suites that act on the *whole* shared recordings directory
//  against the ones whose fixtures live there across a suspension point.
//
//  `RecordingRecovery`'s orphan sweep moves every `.m4a` without a row in its
//  own container to quarantine, and `AudioFileStore.deleteAllAudio` removes
//  them all. Both are synchronous, so on their own they never interleave with
//  another main-actor test — but an async test that awaits (the capture
//  journal rebuild exports for about a second) hands the main actor to them,
//  and its fixture is gone when it resumes. Nesting the suites here makes
//  `.serialized` cover all of them; a suite outside it must not sweep or wipe
//  the directory.
//

import Testing

@Suite(.serialized)
enum RecordingsDirectorySuite {}
