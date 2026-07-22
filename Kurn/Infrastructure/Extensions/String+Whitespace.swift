//
//  String+Whitespace.swift
//  Kurn
//
//  Recovers real whitespace from escape sequences an LLM sometimes double-escapes
//  into the JSON it returns for a summary. When a model writes `"\\n"` in its
//  payload, `JSONDecoder` yields the two literal characters `\` + `n`, which then
//  render verbatim as "\n" instead of a line break. This normalizes those literal
//  sequences back to the whitespace they were meant to be.
//

import Foundation

extension String {
    /// Convert literal `\n` / `\r` / `\t` escape sequences (two-character
    /// backslash + letter) into their real whitespace. Real newlines/tabs already
    /// in the string are untouched, and text without a backslash short-circuits.
    func unescapingLiteralWhitespace() -> String {
        guard contains("\\") else { return self }
        return self
            .replacingOccurrences(of: "\\r\\n", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\r", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
    }
}
