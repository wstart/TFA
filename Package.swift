// swift-tools-version:6.0
import PackageDescription
import Foundation

// Base targets — always present (this is what a public clone gets).
var targets: [Target] = [
    // Core: tmux control protocol, PTY transport, models. No UI / third-party deps.
    .target(
        name: "TmuxKit",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // Super-agent domain: tickets, engine state machine, ~/.tfa/superagent.db. Foundation + SQLite only;
    // shared by the app (which runs the effects) and the `tfa` CLI (which submits commands).
    .target(
        name: "SuperagentCore",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // `tfa`: the command line the 主管 (router) and the ticket workers use to talk to TFA. The logic is a
    // library so its tests link (a test bundle can't test two executable targets — Mux and the CLI).
    .target(
        name: "TFACLIKit",
        dependencies: ["SuperagentCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    .executableTarget(
        name: "TFACLI",
        dependencies: ["TFACLIKit", "SuperagentCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // SwiftUI app (depends on SwiftTerm for the terminal view).
    .executableTarget(
        name: "Mux",
        dependencies: [
            "TmuxKit",
            "SuperagentCore",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
    // axis-claude: terminal coding agent for the local axis-model server. Foundation only.
    .executableTarget(
        name: "AxisClaude",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

// Local-only tests: the `Tests/` directory is gitignored (kept out of the public repo), so a fresh
// clone has no test sources. We add the test targets ONLY when those sources exist on disk — that
// way `swift test` works locally, while a public clone (no Tests/) still resolves and builds cleanly
// instead of erroring on a target pointing at a missing directory.
if FileManager.default.fileExists(atPath: "Tests/TmuxKitTests") {
    targets.append(.testTarget(
        name: "TmuxKitTests",
        dependencies: ["TmuxKit"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ))
}
if FileManager.default.fileExists(atPath: "Tests/MuxTests") {
    targets.append(.testTarget(
        name: "MuxTests",
        dependencies: [
            "Mux",
            "TmuxKit",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ))
}
if FileManager.default.fileExists(atPath: "Tests/SuperagentCoreTests") {
    targets.append(.testTarget(
        name: "SuperagentCoreTests",
        dependencies: ["SuperagentCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ))
}
if FileManager.default.fileExists(atPath: "Tests/TFACLITests") {
    targets.append(.testTarget(
        name: "TFACLITests",
        dependencies: ["TFACLIKit", "SuperagentCore"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ))
}
if FileManager.default.fileExists(atPath: "Tests/AxisClaudeTests") {
    targets.append(.testTarget(
        name: "AxisClaudeTests",
        dependencies: ["AxisClaude"],
        swiftSettings: [.swiftLanguageMode(.v5)]
    ))
}

let package = Package(
    name: "Mux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TmuxKit", targets: ["TmuxKit"]),
        .executable(name: "Mux", targets: ["Mux"]),
        .executable(name: "axis-claude", targets: ["AxisClaude"]),
        .executable(name: "tfa", targets: ["TFACLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
    ],
    targets: targets
)
