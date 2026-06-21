//
//  ColorHexTests.swift
//  KurnTests
//

import SwiftUI
import Testing
@testable import Kurn

struct ColorHexTests {

    @Test func speakerHexCyclesThroughPalette() {
        let paletteCount = Color.speakerPalette.count
        #expect(Color.speakerHex(for: 0) == Color.speakerPalette[0])
        #expect(Color.speakerHex(for: paletteCount) == Color.speakerPalette[0])
        #expect(Color.speakerHex(for: paletteCount + 2) == Color.speakerPalette[2])
    }

    @Test func speakerHexClampsNegativeIndexToFirstColor() {
        #expect(Color.speakerHex(for: -1) == Color.speakerPalette[0])
    }

    @Test func malformedHexFallsBackToGray() {
        let env = EnvironmentValues()
        #expect(Color(hex: "not-a-color").resolve(in: env) == Color.gray.resolve(in: env))
        #expect(Color(hex: "#ABCD").resolve(in: env) == Color.gray.resolve(in: env))
    }

    @Test func validHexWithAndWithoutHashParsesToSameColor() {
        let env = EnvironmentValues()
        let withHash = Color(hex: "#4C6EF5")
        let withoutHash = Color(hex: "4C6EF5")
        #expect(withHash.resolve(in: env) == withoutHash.resolve(in: env))
    }
}
