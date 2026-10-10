//
//  SummaryDraftPreview.swift
//  KurnCore
//
//  The readable draft of a summary while it is still streaming. A summary is
//  generated as JSON (`{"sections":[{"title":…,"body":…,"items":[…]}]}`), and
//  showing that raw would put keys, braces and `\n` escapes in front of the
//  user. This walks the JSON incrementally — one fragment at a time, never
//  needing the rest of the document — and emits only the text a reader
//  cares about: each section's title on its own line, its body, its items as
//  bullets. Values are emitted as they arrive, so the draft grows character
//  by character like a chat reply; keys are buffered until they close, since
//  they decide where a value goes.
//
//  Deliberately unformatted and forgiving: it is a preview of work in
//  progress, replaced by the parsed summary the moment generation finishes.
//  Anything that is not a section title, body or item (photo references,
//  unknown keys, prose or code fences around the JSON) is simply not shown.
//

import Foundation

public struct SummaryDraftPreview: Sendable, Equatable {
    /// The readable draft so far.
    public private(set) var text = ""
    /// Approximate words in `text`; see `StreamedWordCount`.
    public var words: Int { wordCount.words }

    /// `isSection` marks an object that is an element of the top-level
    /// `sections` array (and an array belonging to one): only those carry
    /// text worth showing, so a `body` key nested anywhere else is ignored.
    private enum Container: Equatable {
        case object(key: String?, isSection: Bool)
        case array(key: String?, inSection: Bool)
    }

    private var stack: [Container] = []
    private var inString = false
    private var stringIsKey = false
    private var keyBuffer = ""
    private var valueTarget: ValueTarget?
    private var escape = EscapeState.none
    private var pendingHighSurrogate: UInt32?
    private var wordCount = StreamedWordCount()

    private enum ValueTarget: Equatable {
        case title, body, item
    }

    private enum EscapeState: Equatable {
        case none
        case backslash
        case unicode(String)
    }

    public init() {}

    public mutating func add(_ fragment: String) {
        for scalar in fragment.unicodeScalars {
            if inString {
                consumeInString(scalar)
            } else {
                consumeStructure(scalar)
            }
        }
    }

    // MARK: - Structure

    private mutating func consumeStructure(_ scalar: Unicode.Scalar) {
        switch scalar {
        case "{":
            let isSection: Bool
            if case .array(let key, _) = stack.last { isSection = key == "sections" } else { isSection = false }
            stack.append(.object(key: nil, isSection: isSection))
        case "[":
            let inSection: Bool
            if case .object(_, let isSection) = stack.last { inSection = isSection } else { inSection = false }
            stack.append(.array(key: lastClosedKey, inSection: inSection))
        case "}", "]":
            if !stack.isEmpty { stack.removeLast() }
        case "\"":
            beginString()
        case ",":
            clearKeyIfInObject()
        default:
            break
        }
    }

    /// The key a value in the innermost object belongs to, once its `:` has
    /// been read.
    private var lastClosedKey: String? {
        guard case .object(let key, _) = stack.last else { return nil }
        return key
    }

    private mutating func clearKeyIfInObject() {
        setKeyOfInnermostObject(nil)
    }

    private mutating func beginString() {
        inString = true
        switch stack.last {
        case .object(let key, _) where key == nil:
            stringIsKey = true
            keyBuffer = ""
            valueTarget = nil
        case .object(let key, let isSection):
            stringIsKey = false
            valueTarget = isSection ? Self.target(forKey: key, inArray: false) : nil
        case .array(let key, let inSection):
            stringIsKey = false
            valueTarget = inSection ? Self.target(forKey: key, inArray: true) : nil
        case nil:
            stringIsKey = false
            valueTarget = nil
        }
        startValue()
    }

    private static func target(forKey key: String?, inArray: Bool) -> ValueTarget? {
        switch (key, inArray) {
        case ("title", false): return .title
        case ("body", false): return .body
        case ("items", true): return .item
        default: return nil
        }
    }

    private mutating func startValue() {
        switch valueTarget {
        case .title:
            if !text.isEmpty { emit(text.hasSuffix("\n") ? "\n" : "\n\n") }
        case .item:
            if !text.isEmpty, !text.hasSuffix("\n") { emit("\n") }
            emit("• ")
        case .body, nil:
            break
        }
    }

    private mutating func endString() {
        inString = false
        escape = .none
        pendingHighSurrogate = nil
        if stringIsKey {
            // The key takes effect once its `:` arrives; recording it now is
            // equivalent, since nothing else can come between them.
            setKeyOfInnermostObject(keyBuffer)
            stringIsKey = false
            return
        }
        if valueTarget != nil, !text.hasSuffix("\n") { emit("\n") }
        valueTarget = nil
    }

    private mutating func setKeyOfInnermostObject(_ key: String?) {
        guard case .object(_, let isSection) = stack.last else { return }
        stack[stack.count - 1] = .object(key: key, isSection: isSection)
    }

    // MARK: - Strings

    private mutating func consumeInString(_ scalar: Unicode.Scalar) {
        switch escape {
        case .backslash:
            escape = .none
            switch scalar {
            case "n", "r": appendCharacter("\n")
            case "t": appendCharacter(" ")
            case "u": escape = .unicode("")
            case "b", "f": break
            default: appendCharacter(scalar)
            }
        case .unicode(let digits):
            let collected = digits + String(scalar)
            guard collected.count == 4 else {
                escape = .unicode(collected)
                return
            }
            escape = .none
            if let value = UInt32(collected, radix: 16) { appendCodeUnit(value) }
        case .none:
            switch scalar {
            case "\\": escape = .backslash
            case "\"": endString()
            default: appendCharacter(scalar)
            }
        }
    }

    /// A `\uXXXX` escape; joins a UTF-16 surrogate pair split across two.
    private mutating func appendCodeUnit(_ value: UInt32) {
        if (0xD800...0xDBFF).contains(value) {
            pendingHighSurrogate = value
            return
        }
        if (0xDC00...0xDFFF).contains(value), let high = pendingHighSurrogate {
            pendingHighSurrogate = nil
            let combined = 0x10000 + ((high - 0xD800) << 10) + (value - 0xDC00)
            if let scalar = Unicode.Scalar(combined) { appendCharacter(scalar) }
            return
        }
        pendingHighSurrogate = nil
        if let scalar = Unicode.Scalar(value) { appendCharacter(scalar) }
    }

    private mutating func appendCharacter(_ scalar: Unicode.Scalar) {
        if stringIsKey {
            keyBuffer.unicodeScalars.append(scalar)
        } else if valueTarget != nil {
            emit(String(scalar))
        }
    }

    private mutating func emit(_ piece: String) {
        text += piece
        wordCount.add(piece)
    }
}

/// One update of a streaming summary's draft, as handed to the UI.
/// `sequence` increases with every update of a run — including the empty
/// draft that opens each new request — so a receiver that hops threads can
/// drop an update overtaken by a newer one instead of flickering back to
/// stale text.
public struct SummaryDraftSnapshot: Sendable, Equatable {
    public let sequence: Int
    public let text: String
    public let words: Int

    public init(sequence: Int, text: String, words: Int) {
        self.sequence = sequence
        self.text = text
        self.words = words
    }
}
