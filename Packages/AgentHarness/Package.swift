// swift-tools-version: 6.0
//
// AgentHarness is a standalone, Foundation-only sequential agent loop with
// streaming model/tool protocols, context compaction and vendor wire formats.
// No app dependencies or transport implementation; run `swift test` on Linux
// or Apple platforms. Platform floors only reflect the APIs this package uses.

import PackageDescription

let package = Package(
    name: "AgentHarness",
    platforms: [.iOS(.v16), .macOS(.v13), .watchOS(.v10)],
    products: [.library(name: "AgentHarness", targets: ["AgentHarness"])],
    targets: [
        .target(name: "AgentHarness"),
        .testTarget(name: "AgentHarnessTests", dependencies: ["AgentHarness"])
    ]
)
