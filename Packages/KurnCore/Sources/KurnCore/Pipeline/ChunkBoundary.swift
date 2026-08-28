//
//  ChunkBoundary.swift
//  KurnCore
//
//  Where to end a chunk, given where it would end on a fixed grid and the times
//  the caller would rather cut at.
//
//  A fixed grid cuts wherever 5 or 10 minutes happens to land, which is mid-word
//  far more often than not: the word is split, truncated or duplicated across
//  the two requests, and nothing downstream can tell. It is also the worst place
//  to cut for a different reason — a chunk boundary is a decoder restart, and a
//  restart into the middle of an utterance is exactly the condition Whisper
//  hallucinates over.
//
//  The app already knows where the silences are; it computes them for VAD and
//  then chose chunk boundaries without consulting them. This does the
//  consulting. It is pure, and it has to stay deterministic for the same input:
//  a resumed transcription only reuses its checkpoint when the chunk plan comes
//  out identical, so a boundary that wandered between runs would silently
//  discard the work of every completed chunk.
//

import Foundation

public enum ChunkBoundary {

    /// How far a boundary may move to reach a silence. Wide enough to find one
    /// in a busy meeting, narrow enough that the memory and upload-size bounds
    /// the chunk length exists to enforce still hold.
    public static let tolerance: TimeInterval = 30

    /// A chunk shorter than this is not worth the per-chunk overhead, and near
    /// the end of a file could produce a sliver.
    public static let minimumDuration: TimeInterval = 30

    public static func end(
        start: TimeInterval,
        nominalEnd: TimeInterval,
        total: TimeInterval,
        candidates: [TimeInterval],
        tolerance: TimeInterval = tolerance
    ) -> TimeInterval {
        // The final chunk ends where the audio does; there is nothing to snap to
        // and moving it would leave a tail unread.
        guard nominalEnd < total else { return total }

        let lower = max(start + minimumDuration, nominalEnd - tolerance)
        let upper = min(total, nominalEnd + tolerance)
        guard lower <= upper else { return nominalEnd }

        // Closest to the nominal boundary, so the chunk length stays as close as
        // possible to what the caller sized it for. `candidates` is sorted, so
        // ties resolve to the earlier one and the plan is reproducible.
        let best = candidates
            .filter { $0 >= lower && $0 <= upper }
            .min { abs($0 - nominalEnd) < abs($1 - nominalEnd) }
        return best ?? nominalEnd
    }

    /// Times it is safe to cut at, from the speech regions the VAD already
    /// produced: the middle of each silence between them.
    ///
    /// The midpoint rather than an edge because both edges belong to speech —
    /// cutting at the end of one region clips the tail of a word, and at the
    /// start of the next clips its onset.
    public static func cutPoints(betweenSpeechRegions regions: [SpeechRegion]) -> [TimeInterval] {
        let sorted = regions.sorted { $0.start < $1.start }
        var points: [TimeInterval] = []
        for (previous, next) in zip(sorted, sorted.dropFirst()) where next.start > previous.end {
            points.append((previous.end + next.start) / 2)
        }
        return points
    }

    /// Cut points on the **compacted** timeline, which is the one the engine sees
    /// when VAD compaction ran. The compactor writes a fixed silent gap before
    /// every region but the first, so each region's `compactedStart` has silence
    /// immediately behind it — that is the whole set of safe cuts, and the
    /// original-timeline points computed above would be meaningless here.
    public static func cutPoints(inCompactedTimeline map: [TimelineSegment]) -> [TimeInterval] {
        map.dropFirst().map(\.compactedStart)
    }
}
