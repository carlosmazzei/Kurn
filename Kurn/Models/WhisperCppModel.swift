//
//  WhisperCppModel.swift
//  Kurn
//
//  The GGML weight files the on-device whisper.cpp engine can run, and where to
//  fetch them. Only quantized (q5) builds are offered: they are roughly half the
//  size of the f16 originals at nearly the same accuracy, which matters a great
//  deal when the user is downloading them over cellular onto a phone.
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

    /// HuggingFace repository hosting whisper.cpp's converted GGML weights
    /// (the one `models/download-ggml-model.sh` upstream uses), pinned to a
    /// fixed commit rather than the moving `main` branch so a later push
    /// cannot change what this app downloads.
    static let repositoryRevision = "5359861c739e955e79d9a303bcbc70fb988958b1"

    private static let repositoryURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/\(repositoryRevision)"
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

    /// SHA-256 of the weight file at `repositoryRevision` — the Git LFS object
    /// ID committed at that revision, confirmed by hashing the downloaded
    /// bytes. Checked against the received file as `pinnedSHA256`, so a file
    /// swapped at the origin fails the download instead of reaching
    /// whisper.cpp's GGML loader.
    var sha256: String {
        switch self {
        case .base: return "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
        case .small: return "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        case .largeTurbo: return "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        }
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
