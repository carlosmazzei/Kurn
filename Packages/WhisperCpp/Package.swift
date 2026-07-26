// swift-tools-version: 5.9
//
//  Package.swift
//  WhisperCpp
//
//  Thin local package whose only job is to pull in whisper.cpp's official
//  prebuilt XCFramework as a binary target, so the Xcode project can link it
//  without vendoring ~50 MB of binaries into git.
//
//  The target is deliberately named `whisper` to match `whisper.xcframework`
//  inside the release archive, and the module it exports is also `whisper`
//  (see the framework's `module.modulemap`). App code guards on
//  `#if canImport(whisper)`.
//
//  Upgrading: bump the version in the URL, download the new asset and run
//  `swift package compute-checksum whisper-vX.Y.Z-xcframework.zip` (plain
//  SHA-256 of the zip) to replace `checksum`. A stale checksum fails during
//  package resolution, before anything compiles.
//

import PackageDescription

let package = Package(
    name: "WhisperCpp",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "whisper", targets: ["whisper"])
    ],
    targets: [
        .binaryTarget(
            name: "whisper",
            url: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-v1.9.1-xcframework.zip",
            checksum: "8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c"
        )
    ]
)
