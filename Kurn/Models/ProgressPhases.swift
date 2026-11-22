//
//  ProgressPhases.swift
//  Kurn
//
//  Progress vocabulary the pipelines report to the UI: transcription,
//  post-transcription enrichment and chat phases, plus the chunk counter.
//

import Foundation
import KurnCore

/// Fine-grained stage within an in-progress transcription, surfaced to the UI so
/// the user can see what the app is currently doing (e.g. cleaning audio vs.
/// transcribing). Reported by `TranscriptionService` as it advances.
enum TranscriptionPhase: Sendable, Equatable {
    case preparing
    case preprocessing
    /// Detecting the spoken language (only the FluidAudio LID engine reports this;
    /// engines that detect the language themselves skip it).
    case detectingLanguage
    /// Running voice-activity detection to find speech regions.
    case detectingSpeech
    /// Active transcription. `progress` is a fraction in `0...1` when the engine
    /// can report it (e.g. the chunked Whisper path), or `nil` when the stage is
    /// indeterminate (e.g. a single on-device pass). `chunks` carries the current
    /// chunk number and total for long recordings so the UI can show both a bar
    /// and a "chunk X of Y" label.
    case transcribing(progress: Double?, chunks: ChunkProgress? = nil)
    /// Assigning transcript spans to speakers. This is distinct from
    /// transcription because the cloud transcript can already be at 100% while
    /// the on-device diarizer is still preprocessing or analyzing a long file.
    case diarizing(progress: Double?)
    case finalizing
    /// Opt-in LLM correction pass over the fused transcript. Only emitted when
    /// the `.llm` correction engine is actually running; the `.none` engine
    /// never reports this phase and finalizing owns the tail as before.
    case correcting(progress: Double?)

    /// Short, user-facing description of the current stage.
    var displayName: String {
        switch self {
        case .preparing: return NSLocalizedString("phase.preparing", comment: "Preparing")
        case .preprocessing: return NSLocalizedString("phase.preprocessing", comment: "Cleaning audio")
        case .detectingLanguage: return NSLocalizedString("phase.detecting_language", comment: "Detecting language")
        case .detectingSpeech: return NSLocalizedString("phase.detecting_speech", comment: "Detecting speech")
        case .transcribing(let progress, let chunks):
            guard let progress else {
                return NSLocalizedString("phase.transcribing", comment: "Transcribing")
            }
            let percent = Int((progress * 100).rounded())
            if let chunks {
                return String(
                    format: NSLocalizedString("phase.transcribing_chunk_progress", comment: "Transcribing with percent and chunk count"),
                    percent, chunks.completed, chunks.total
                )
            }
            return String(
                format: NSLocalizedString("phase.transcribing_progress", comment: "Transcribing with percent"),
                percent
            )
        case .diarizing(let progress):
            guard let progress else {
                return NSLocalizedString("phase.diarizing", comment: "Separating speakers")
            }
            return String(
                format: NSLocalizedString("phase.diarizing_progress", comment: "Separating speakers with percent"),
                Int((min(1, max(0, progress)) * 100).rounded())
            )
        case .finalizing: return NSLocalizedString("phase.finalizing", comment: "Finalizing")
        case .correcting(let progress):
            guard let progress else {
                return NSLocalizedString("phase.correcting", comment: "Correcting transcript")
            }
            return String(
                format: NSLocalizedString("phase.correcting_progress", comment: "Correcting transcript with percent"),
                Int((min(1, max(0, progress)) * 100).rounded())
            )
        }
    }

    /// The phase's name without its embedded progress percent, for callers
    /// that show the overall `fractionComplete` percent instead.
    var baseName: String {
        switch self {
        case .transcribing: return TranscriptionPhase.transcribing(progress: nil).displayName
        case .diarizing: return TranscriptionPhase.diarizing(progress: nil).displayName
        case .correcting: return TranscriptionPhase.correcting(progress: nil).displayName
        default: return displayName
        }
    }

    /// Overall completion in `0...1` for a single, always-determinate progress
    /// bar. Each stage occupies a fixed band so the bar only ever moves forward —
    /// the indeterminate linear bar rendered as a dead, empty line, leaving the
    /// user with no feedback during the stages between cleaning and transcribing.
    /// Within transcribing, the engine's real sub-progress fills that band.
    var fractionComplete: Double {
        switch self {
        case .preparing: return 0.05
        case .preprocessing: return 0.15
        case .detectingLanguage: return 0.22
        case .detectingSpeech: return 0.28
        case .transcribing(let progress, _): return 0.30 + 0.55 * min(1, max(0, progress ?? 0))
        case .diarizing(let progress): return 0.86 + 0.09 * min(1, max(0, progress ?? 0))
        case .finalizing: return 0.95
        case .correcting(let progress): return 0.95 + 0.05 * min(1, max(0, progress ?? 0))
        }
    }
}

/// Best-effort work that starts only after the transcript has been saved.
///
/// These phases are deliberately separate from `TranscriptionPhase`: a recording
/// is already `.done` while they run, and a failure in any of them must not turn a
/// successful transcription into a failed one.
enum PostTranscriptionPhase: Sendable, Equatable {
    case generatingTitle
    case indexing
    case generatingWiki

    var displayName: String {
        switch self {
        case .generatingTitle:
            return NSLocalizedString("post_phase.generating_title", comment: "Generating meeting title")
        case .indexing:
            return NSLocalizedString("post_phase.indexing", comment: "Indexing transcript")
        case .generatingWiki:
            return NSLocalizedString("post_phase.generating_wiki", comment: "Generating meeting wiki")
        }
    }
}

/// Stage within an explicit knowledge compilation ("Update knowledge"), the
/// same shape `TranscriptionPhase` uses: a name plus an always-determinate
/// `fractionComplete` whose fixed bands only move forward.
enum KnowledgeCompilationPhase: Sendable, Equatable {
    /// The snapshot/read validation before any extraction runs.
    case readingTranscript
    /// Extracting facts from one recording: the 1-based index and the total.
    case extracting(recording: Int, of: Int)
    /// The post-extraction revalidation and integrity checks before commit.
    case checking
    /// The canonical commit itself.
    case publishing

    var displayName: String {
        switch self {
        case .readingTranscript:
            return NSLocalizedString("phase.knowledge.reading", comment: "Reading transcript")
        case .extracting(let recording, let total):
            return String(
                format: NSLocalizedString("phase.knowledge.extracting", comment: "Extracting facts per recording"),
                recording, total
            )
        case .checking:
            return NSLocalizedString("phase.knowledge.checking", comment: "Checking facts")
        case .publishing:
            return NSLocalizedString("phase.knowledge.publishing", comment: "Publishing")
        }
    }

    /// Extraction owns the wide middle band; within it the fraction advances
    /// one step per recording completed.
    var fractionComplete: Double {
        switch self {
        case .readingTranscript: return 0.1
        case .extracting(let recording, let total):
            // `recording` is the one being extracted now (1-based), so only
            // the recordings before it count as done — the bar starts at 15%
            // and advances when each recording finishes, never jumps ahead.
            return 0.15 + 0.6 * min(1, Double(max(0, recording - 1)) / Double(max(1, total)))
        case .checking: return 0.8
        case .publishing: return 0.95
        }
    }
}

/// Chunk counter surfaced in the transcription progress UI.
///
/// `completed` is the chunk currently being shown to the user: it is the index
/// of the chunk in flight (1-based), not the count of fully finished chunks.
/// For example, when the first of three chunks is being uploaded, the UI shows
/// "chunk 1 of 3" even though zero chunks have finished. Once the first chunk
/// completes, the display advances to "chunk 2 of 3" while the next chunk is
/// processed. `total` is the total number of chunks in the plan.
struct ChunkProgress: Sendable, Equatable {
    let completed: Int
    let total: Int
}
