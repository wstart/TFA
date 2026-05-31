// swift-tools-version:6.0
import PackageDescription

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
    targets: [
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
)
