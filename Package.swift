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
    // SwiftUI app (depends on SwiftTerm for the terminal view).
    .executableTarget(
        name: "Mux",
        dependencies: [
            "TmuxKit",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
        ],
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

let package = Package(
    name: "Mux",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TmuxKit", targets: ["TmuxKit"]),
        .executable(name: "Mux", targets: ["Mux"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
    ],
    targets: targets
)
