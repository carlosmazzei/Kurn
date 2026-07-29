//
//  TextNormalizer.swift
//  KurnTests
//
//  Turns two transcripts into comparable token sequences.
//
//  This exists for *measurement only*, and deliberately does not run on anything
//  the user reads. Word error rate compares what was said, not how it was
//  written, so "Vamos começar às 9h." and "vamos comecar as 9 h" have to count as
//  the same words — while the transcript on screen should keep its punctuation
//  and capitalization, which is what makes it readable. Normalizing the stored
//  transcript would be destroying information to make a number look better.
//
//  Language coverage is a real limit here. The app ships seven languages, and the
//  standard normalizers (Whisper's, NIST's) are English-specific: number
//  expansion, contraction splitting and filler-word lists are all per-language
//  and none of them are done here. What is done is language-neutral —
//  compatibility normalization, case folding, punctuation removal, whitespace
//  collapse — so the resulting rate is comparable *between runs on the same
//  material*, which is what a regression harness needs. It is not directly
//  comparable to a published WER for the same audio.
//

import Foundation

enum TextNormalizer {

    /// Comparable tokens: lowercased, compatibility-normalized, punctuation
    /// removed.
    ///
    /// Ideographic and kana text is split per character rather than per word,
    /// because it is written without spaces and word tokens would be whole
    /// clauses. That makes the result a *character* error rate for those
    /// languages, which is the convention for them anyway — but it does mean a
    /// Chinese rate and a Portuguese rate are not the same measurement.
    static func tokens(_ text: String) -> [String] {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        let words = folded.split { !$0.isLetter && !$0.isNumber }
        return words.flatMap { word -> [String] in
            let string = String(word)
            guard string.contains(where: isUnsegmented) else { return [string] }
            return string.map(String.init)
        }
    }

    /// The tokens joined back into a string, for eyeballing a diff.
    static func normalized(_ text: String) -> String {
        tokens(text).joined(separator: " ")
    }

    /// Whether a character belongs to a script written without word spacing.
    /// Hangul is deliberately excluded — Korean *is* space-segmented.
    private static func isUnsegmented(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF: return true   // Hiragana, Katakana
        case 0x3400...0x4DBF: return true   // CJK Unified Ideographs Extension A
        case 0x4E00...0x9FFF: return true   // CJK Unified Ideographs
        case 0xF900...0xFAFF: return true   // CJK Compatibility Ideographs
        default: return false
        }
    }
}
