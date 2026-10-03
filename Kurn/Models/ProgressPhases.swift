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

/// Fine-grained stage within a "chat with your meetings" turn, surfaced to the
/// UI so a reply reads as visible work rather than an opaque spinner — the
/// same idea as `TranscriptionPhase`, reported by `MeetingChatService` as it
/// advances through query rewriting, retrieval, reranking, and generation.
/// Not every turn passes through every phase: a single meeting whose
/// transcript fits the model's context skips straight to `.answering`.
enum ChatPhase: Sendable, Equatable {
    case rewritingQuery
    case retrieving
    case reranking
    /// Reading condensed per-meeting wiki articles into the prompt. Only the
    /// library-wide "Ask" reaches this — a single meeting's chat has no
    /// cross-meeting notes to read.
    case synthesizing
    /// Generating the reply itself; this is the phase during which the
    /// answer streams into the conversation.
    case answering

    /// Short, user-facing description of the current stage.
    var displayName: String {
        switch self {
        case .rewritingQuery: return NSLocalizedString("chat.phase.rewriting_query", comment: "Rewriting the question")
        case .retrieving: return NSLocalizedString("chat.phase.retrieving", comment: "Searching passages")
        case .reranking: return NSLocalizedString("chat.phase.reranking", comment: "Ranking passages")
        case .synthesizing: return NSLocalizedString("chat.phase.synthesizing", comment: "Reading meeting notes")
        case .answering: return NSLocalizedString("chat.phase.answering", comment: "Writing the answer")
        }
    }

    /// SF Symbol paired with `displayName` in the reasoning row.
    var systemImage: String {
        switch self {
        case .rewritingQuery: return "text.magnifyingglass"
        case .retrieving: return "magnifyingglass"
        case .reranking: return "arrow.up.arrow.down"
        case .synthesizing: return "doc.text.magnifyingglass"
        case .answering: return "sparkles"
        }
    }
}

/// One update from an in-flight chat answer: either a change of `ChatPhase`
/// (the retrieval/generation pipeline advancing) or a text delta to append to
/// the streaming reply. May be delivered from a background executor — the
/// receiver hops to the main actor itself, the same contract as
/// `TranscriptionService.PhaseHandler`.
enum ChatStreamEvent: Sendable {
    case phase(ChatPhase)
    /// Supplementary status detail for the current phase, e.g. "(2/5)" while
    /// `.synthesizing` works through several map-reduce blocks of meeting
    /// notes — so a phase that can legitimately take a while (a large
    /// library) still visibly advances instead of sitting on one static
    /// label. Cleared whenever the phase changes or the first delta arrives.
    case progress(String)
    case delta(String)
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
