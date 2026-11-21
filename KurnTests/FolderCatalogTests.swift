//
//  FolderCatalogTests.swift
//  KurnTests
//
//  Guards the small invariants the folder form depends on: the catalog
//  defaults must match what `Folder` falls back to, the lists must be
//  non-empty (the picker UI would silently render nothing otherwise), and
//  hex values must be parseable.
//

import Foundation
import Testing
@testable import Kurn

struct FolderCatalogTests {

    @Test func iconCatalogDefaultMatchesFolderModelDefault() {
        let folder = Folder(name: "Sample")
        #expect(folder.iconName == FolderIconCatalog.default)
    }

    @Test func colorPaletteDefaultMatchesFolderModelDefault() {
        let folder = Folder(name: "Sample")
        #expect(folder.colorHex == FolderColorPalette.default)
    }

    @Test func iconCatalogIsNonEmptyAndIncludesItsDefault() {
        #expect(!FolderIconCatalog.icons.isEmpty)
        #expect(FolderIconCatalog.icons.contains(FolderIconCatalog.default))
    }

    @Test func colorPaletteIsNonEmptyAndIncludesItsDefault() {
        #expect(!FolderColorPalette.colors.isEmpty)
        #expect(FolderColorPalette.colors.contains(FolderColorPalette.default))
    }

    @Test func everyPaletteEntryIsAWellFormedHexString() {
        let pattern = #/^#[0-9A-Fa-f]{6}$/#
        for hex in FolderColorPalette.colors {
            #expect((try? pattern.wholeMatch(in: hex)) != nil, "Bad hex: \(hex)")
        }
    }

    @Test func everyFolderIconHasALocalizedAccessibleNameAndUnknownSymbolFallsBack() {
        for symbol in FolderIconCatalog.icons {
            let label = FolderIconCatalog.accessibleName(for: symbol)
            #expect(!label.isEmpty)
            #expect(label != symbol, "Expected localized name for \(symbol), got raw symbol")
            #expect(!label.hasPrefix("folder.icon."), "Unresolved localization key for \(symbol): \(label)")
        }
        #expect(FolderIconCatalog.accessibleName(for: "custom.unknown.symbol") == "custom.unknown.symbol")
    }
}
