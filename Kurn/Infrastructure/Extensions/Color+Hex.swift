//
//  Color+Hex.swift
//  Kurn
//
//  Hex <-> Color conversion for per-speaker color tags stored as strings.
//

import Foundation
import SwiftUI

extension Color {
    /// Parse "#RRGGBB" or "RRGGBB". Falls back to gray on malformed input.
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard cleaned.count == 6, Scanner(string: cleaned).scanHexInt64(&rgb) else {
            self = .gray
            return
        }
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        self = Color(red: r, green: g, blue: b)
    }

    /// A palette used to auto-assign distinct colors to detected speakers.
    static let speakerPalette: [String] = [
        "#4C6EF5", // indigo
        "#E8590C", // orange
        "#2F9E44", // green
        "#9C36B5", // grape
        "#1098AD", // cyan
        "#E03131", // red
        "#F08C00", // amber
        "#5C940D" // lime
    ]

    /// Returns a palette hex for the Nth speaker, cycling if needed.
    static func speakerHex(for index: Int) -> String {
        guard index >= 0 else { return speakerPalette[0] }
        return speakerPalette[index % speakerPalette.count]
    }
}
