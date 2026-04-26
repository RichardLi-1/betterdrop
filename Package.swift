// swift-tools-version: 5.10
// Package.swift is used for the engine library and tests.
// The macOS app target (with MenuBarExtra and Window scenes) requires Xcode —
// open BetterDrop.xcodeproj and point it at BetterDrop/ as the source directory.

import PackageDescription

let package = Package(
    name: "BetterDrop",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],
    products: [
        // Engine + persistence as a standalone library — importable by both the
        // macOS app and a future iOS companion app.
        .library(name: "BetterDropEngine", targets: ["BetterDropEngine"]),
    ],
    targets: [
        .target(
            name: "BetterDropEngine",
            path: "BetterDrop",
            exclude: [
                // App-layer files that require SwiftUI / AppKit
                "BetterDropApp.swift",
                "Views",
                "Resources",
            ],
            sources: [
                "Models",
                "Store",
                "Engine",
                "Persistence",
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "BetterDropEngineTests",
            dependencies: ["BetterDropEngine"],
            path: "Tests/BetterDropEngineTests"
        ),
    ]
)
