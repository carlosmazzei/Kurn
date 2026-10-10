//
//  StreamedWordCount.swift
//  KurnCore
//
//  A running word count over text that arrives in fragments — the progress
//  a streamed summary reports while the model is still writing. A word is a
//  run of letters or digits, so a word split across two fragments ("summ" +
//  "ary") counts once, and the JSON punctuation a summary is wrapped in
//  counts as nothing. Approximate by design: the JSON keys ("title",
//  "body") are counted too, and a script written without spaces counts a
//  whole run as one word. It only has to show that text is arriving and
//  roughly how much.
//

import Foundation

public struct StreamedWordCount: Sendable, Equatable {
    public private(set) var words = 0
    private var inWord = false

    public init() {}

    /// Fold in the next fragment and return the running count.
    @discardableResult
    public mutating func add(_ fragment: String) -> Int {
        for scalar in fragment.unicodeScalars {
            let isWordScalar = CharacterSet.alphanumerics.contains(scalar)
            if isWordScalar, !inWord { words += 1 }
            inWord = isWordScalar
        }
        return words
    }
}
