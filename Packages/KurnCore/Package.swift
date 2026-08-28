// swift-tools-version: 6.0
//
//  Package.swift
//  KurnCore
//
//  Pure-Foundation logic extracted from the Kurn app target so it can be
//  compiled and tested with `swift test` on Linux, without Xcode or a
//  simulator. See docs/roadmap.md, "The change that isn't a feature: SPM
//  extraction".
//
//  Platform floors deliberately stay low (not the app's actual iOS 26 /
//  watchOS 10 deployment targets): nothing here calls a version-gated API,
//  so the floor only needs to be low enough that SwiftPM's own availability
//  checking doesn't get in the way. `watchOS` is declared even though
//  KurnWatch doesn't consume this package yet, so a future change to share
//  a type like `TranscriptionStatus` with the watch app needs no manifest
//  edit first.
//

import PackageDescription

let package = Package(
    name: "KurnCore",
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v10)],
    products: [
        .library(name: "KurnCore", targets: ["KurnCore"])
    ],
    targets: [
        .target(name: "KurnCore", path: "Sources/KurnCore"),
        .testTarget(name: "KurnCoreTests", dependencies: ["KurnCore"], path: "Tests/KurnCoreTests")
    ]
)
