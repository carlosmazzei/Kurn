//
//  DiagnosticReportFormatter.swift
//  Kurn
//
//  Formats a MetricKit diagnostic payload into a human-readable text report.
//  Pure and MetricKit-free in its signature (takes primitives the caller
//  already extracted from the live payload) so it's unit-testable with
//  hand-authored fixture JSON instead of OS-constructed objects.
//

import Foundation

enum DiagnosticReportFormatter {
    enum Kind: String {
        case crash
        case hang
    }

    /// Header + pretty-printed JSON body. Apple's own `jsonRepresentation()`
    /// already carries symbolicated-if-available frames and thread state, so
    /// this re-serializes it for readability rather than hand-rolling a call
    /// stack tree walker that risks silently dropping information.
    static func format(
        kind: Kind,
        receivedAt: Date,
        appVersion: String,
        osVersion: String,
        jsonRepresentation: Data
    ) -> String {
        let formatter = ISO8601DateFormatter()
        var out = "# Kurn diagnostic report (\(kind.rawValue))\n"
        out += "Received: \(formatter.string(from: receivedAt))\n"
        out += "App version: \(appVersion)\n"
        out += "OS version: \(osVersion)\n\n"
        out += prettyPrintedJSON(from: jsonRepresentation)
        return out
    }

    private static func prettyPrintedJSON(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        return text
    }
}
