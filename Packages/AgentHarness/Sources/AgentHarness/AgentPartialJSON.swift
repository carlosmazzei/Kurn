import Foundation

/// The best-effort value of a JSON text that is still arriving (a tool call's arguments while they
/// stream): the longest prefix that ends on a whole value, with the containers it leaves open
/// closed, and a string value cut off mid-way kept as far as it got. A key with no value yet, a
/// number or literal still being written and a half escape are left out. Display only: the call
/// that runs is always the complete arguments, validated as usual.
public enum AgentPartialJSON {
    /// The value `text` describes so far, or nil when nothing whole has arrived.
    public static func parse(_ text: String) -> JSONValue? {
        var scanner = Scanner()
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() { scanner.consume(scalar, at: index) }
        var completion: String?
        if scanner.inString, !scanner.stringIsKey {
            // A string value cut off: keep what arrived, without a half escape.
            let prefix = string(scalars[..<(scanner.pendingEscapeStart ?? scalars.count)])
            completion = prefix + "\"" + scanner.closers(scanner.stack)
        }
        if let completion, let value = try? JSONValue.parse(completion) { return value }
        if scanner.inToken, scanner.stack.last.map({ !$0.isObject || !$0.expectsKey }) ?? true {
            // A number or literal that may already be whole ("12", "true").
            let candidate = text + scanner.closers(scanner.stack)
            if let value = try? JSONValue.parse(candidate) { return value }
        }
        guard let safe = scanner.lastSafe else { return nil }
        return try? JSONValue.parse(string(scalars[..<safe.end]) + safe.closers)
    }

    private static func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    private struct Frame {
        let isObject: Bool
        var expectsKey: Bool
    }

    private struct Scanner {
        var stack: [Frame] = []
        var inString = false
        var stringIsKey = false
        var escaping = false
        var pendingEscapeStart: Int?
        var unicodeDigits = 0
        var inToken = false
        /// The end of the longest prefix ending on a whole value, and what closes it.
        var lastSafe: (end: Int, closers: String)?

        func closers(_ frames: [Frame]) -> String {
            String(frames.reversed().map { $0.isObject ? "}" : "]" })
        }

        mutating func valueEnded(at end: Int) {
            if let last = stack.indices.last, stack[last].isObject { stack[last].expectsKey = false }
            lastSafe = (end, closers(stack))
        }

        mutating func consume(_ scalar: Unicode.Scalar, at index: Int) {
            if inString {
                if unicodeDigits > 0 {
                    unicodeDigits -= 1
                    if unicodeDigits == 0 { pendingEscapeStart = nil }
                } else if escaping {
                    escaping = false
                    if scalar == "u" { unicodeDigits = 4 } else { pendingEscapeStart = nil }
                } else if scalar == "\\" {
                    escaping = true
                    pendingEscapeStart = index
                } else if scalar == "\"" {
                    inString = false
                    if !stringIsKey {
                        valueEnded(at: index + 1)
                    } else if let last = stack.indices.last {
                        // A key is followed by its value, which is not a key.
                        stack[last].expectsKey = false
                    }
                }
                return
            }
            let isTokenScalar = scalar.properties.isAlphabetic || ("0"..."9").contains(scalar)
                || scalar == "-" || scalar == "+" || scalar == "."
            if inToken, !isTokenScalar {
                inToken = false
                valueEnded(at: index)
            }
            switch scalar {
            case "\"":
                inString = true
                stringIsKey = stack.last.map { $0.isObject && $0.expectsKey } ?? false
            case "{", "[":
                stack.append(Frame(isObject: scalar == "{", expectsKey: scalar == "{"))
                lastSafe = (index + 1, closers(stack))
            case "}", "]":
                guard !stack.isEmpty else { return }
                stack.removeLast()
                valueEnded(at: index + 1)
            case ",":
                if let last = stack.indices.last, stack[last].isObject { stack[last].expectsKey = true }
            case ":", " ", "\n", "\r", "\t":
                break
            default:
                if isTokenScalar { inToken = true }
            }
        }
    }
}
