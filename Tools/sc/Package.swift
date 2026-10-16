// swift-tools-version: 6.0
//
// `sc` — the Second Chance developer CLI. Run it through `./sc` at the repo
// root, which builds this package and then runs it. See docs/dev-cli.md.

import PackageDescription

let package = Package(
    name: "sc",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sc", targets: ["sc"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.8.2")),
        .package(url: "https://github.com/swiftlang/swift-subprocess", .upToNextMinor(from: "1.0.1")),
        .package(url: "https://github.com/tuist/Noora", .upToNextMinor(from: "0.57.5")),
    ],
    targets: [
        .executableTarget(
            name: "sc",
            dependencies: ["SCKit"]
        ),
        .target(
            name: "SCKit",
            dependencies: [
                "GameCatalog",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Noora", package: "Noora"),
            ]
        ),
        // The app's own game database, compiled from symlinks to
        // SecondChance/Models/GameInfo.swift and
        // SecondChance/Services/GameInfoProvider.swift so slugs and titles
        // can never drift from the app. Swift 5 mode because those files
        // belong to the app (Swift 5) and aren't Sendable-clean; Catalog.swift
        // is the public, Sendable face the rest of the tool uses.
        .target(
            name: "GameCatalog",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SCKitTests",
            dependencies: ["SCKit", "GameCatalog"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
