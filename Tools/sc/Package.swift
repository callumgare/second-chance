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
        // The app's own game database, so slugs and titles can never drift
        // from the app.
        .package(path: "../../Packages/GameCatalog"),
        // Loading and checking program bundles, for `sc bundle`.
        .package(path: "../../Packages/WrappBuilder"),
        // Ending a puppet session's Wine, for `sc puppet`.
        .package(path: "../../Packages/Modules/wine"),
        // The builder's own tool, whose module, engine and fmt commands sc
        // runs as its own.
        .package(path: "../../Packages/WrappBuilderCLI"),
    ],
    targets: [
        .executableTarget(
            name: "sc",
            dependencies: ["SCKit"]
        ),
        .target(
            name: "SCKit",
            dependencies: [
                .product(name: "GameCatalog", package: "GameCatalog"),
                .product(name: "WrappBuilder", package: "WrappBuilder"),
                .product(name: "WineKit", package: "wine"),
                .product(name: "WrappBuilderTool", package: "WrappBuilderCLI"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Subprocess", package: "swift-subprocess"),
                .product(name: "Noora", package: "Noora"),
            ]
        ),
        .testTarget(
            name: "SCKitTests",
            dependencies: ["SCKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
