//
//  WhisperCppModel.swift
//  Kurn
//
//  The GGML weight files the on-device whisper.cpp engine can run, and where to
//  fetch them. Only quantized (q5) builds are offered: they are roughly half the
//  size of the f16 originals at nearly the same accuracy, which matters a great
//  deal when the user is downloading them over cellular onto a phone.
//
//  Lives in its own file rather than in `Enums.swift`, which is already past
//  SwiftLint's file-length warning threshold.
//

import Foundation

/// A whisper.cpp weight file, selectable in Settings → Transcription.
///
/// Raw values are persisted in `UserDefaults` (`settings.whisperCppModel`) and
/// embedded in transcription checkpoints, so cases may be added but not renamed.
enum WhisperCppModel: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Smallest usable multilingual model. Fast on any supported device, but
    /// noticeably weaker on accented speech and cross-talk.
    case base
    /// The default: the best accuracy/size trade-off for meeting audio.
    case small
    /// Whisper large-v3-turbo — the most accurate option, and still faster than
    /// `medium` because the turbo decoder has only four layers. Large download
    /// and the heaviest at inference time, so it is opt-in.
    case largeTurbo

    /// Shipped when the user has never chosen one.
    static let `default`: WhisperCppModel = .small

    var id: String { rawValue }

    /// HuggingFace repository hosting whisper.cpp's converted GGML weights.
    /// Matches `models/download-ggml-model.sh` upstream.
    private static let repositoryURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"
    )!

    /// Upstream model identifier, i.e. the `ggml-<name>.bin` suffix.
    var modelName: String {
        switch self {
        case .base: return "base-q5_1"
        case .small: return "small-q5_1"
        case .largeTurbo: return "large-v3-turbo-q5_0"
        }
    }

    var fileName: String { "ggml-\(modelName).bin" }

    /// One folder per variant under the whisper.cpp model root, so Settings →
    /// Storage can report and delete each download independently.
    var folderName: String { "ggml-\(modelName)" }

    var downloadURL: URL {
        Self.repositoryURL.appendingPathComponent(fileName)
    }

    /// Published size of the weight file, used to tell the user what a download
    /// will cost before they consent. Approximate by design — the exact size is
    /// whatever the server reports once the transfer starts.
    var approximateBytes: Int64 {
        switch self {
        case .base: return 57 * 1_000_000
        case .small: return 190 * 1_000_000
        case .largeTurbo: return 574 * 1_000_000
        }
    }

    /// Lower bound a finished download must clear to be treated as complete, so
    /// a truncated transfer is re-fetched instead of handed to whisper.cpp as a
    /// corrupt model. Deliberately loose: it only has to catch a partial file.
    var minimumPlausibleBytes: Int64 { approximateBytes / 2 }

    var displayName: String {
        switch self {
        case .base: return NSLocalizedString("whisper_cpp.model.base", comment: "Whisper base model")
        case .small: return NSLocalizedString("whisper_cpp.model.small", comment: "Whisper small model")
        case .largeTurbo: return NSLocalizedString("whisper_cpp.model.large_turbo", comment: "Whisper large v3 turbo model")
        }
    }
}
