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
        // The puppet control sockets' requests and replies, for `sc puppet`.
        .package(path: "../../Packages/PuppetProtocol"),
        // Wine's desktop and output in a puppet session's log, for `sc puppet start --wine`.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(path: "../../Packages/WrappKit"),
        // The app's own game database, so slugs and titles can never drift
        // from the app.
        .package(path: "../../Packages/GameCatalog"),
        // Loading and checking program bundles, for `sc bundle`.
        .package(path: "../../Packages/WrappBuilder"),
        // Ending a puppet session's Wine, for `sc puppet`.
        .package(path: "../../Packages/Modules/wine"),
        // WrappPuppeteer's picture matching, for `sc puppet screen` and
        // its locators (a package of its own, so not PuppeteerCore's
        // SecondChanceKit and Sentry).
        .package(path: "../../Packages/PictureMatching"),
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
                .product(name: "ProcessKit", package: "WrappKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "PictureMatching", package: "PictureMatching"),
                .product(name: "PuppetProtocol", package: "PuppetProtocol"),
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
