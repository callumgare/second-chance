// swift-tools-version: 6.2
//
// `wrapp-builder`, the builder's own command-line tool: it checks, plans
// and formats Wrappfiles, and looks after modules and engines, knowing
// nothing of Second Chance's (docs/dev-cli.md#wrapp-builder). A package of
// its own, so it can move with the builder, and so `sc` can run its
// commands as its own.

import PackageDescription

/// The same settings as the builder's package (WrappBuilder's
/// Package.swift has why).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "WrappBuilderCLI",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "wrapp-builder", targets: ["wrapp-builder"]),
        .library(name: "WrappBuilderTool", targets: ["WrappBuilderTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", .upToNextMinor(from: "1.8.2")),
        .package(path: "../WrappBuilder"),
        .package(path: "../WrappKit"),
        // The shipped modules' executors, which it runs as Second Chance does.
        .package(path: "../Modules/wine"),
        .package(path: "../Modules/nancy-drew"),
        .package(path: "../Modules/scummvm"),
        // The modules' kits, for where their path types' paths are.
        .package(path: "../Modules/dosbox"),
        .package(path: "../Modules/big-fish"),
        .package(path: "../Modules/basilisk"),
    ],
    targets: [
        .executableTarget(
            name: "wrapp-builder",
            dependencies: ["WrappBuilderTool", .product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "WrappBuilderTool",
            dependencies: [
                .product(name: "WrappBuilder", package: "WrappBuilder"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WineExecutor", package: "wine"),
                .product(name: "NancyDrewExecutor", package: "nancy-drew"),
                .product(name: "ScummVMExecutor", package: "scummvm"),
                .product(name: "WineKit", package: "wine"),
                .product(name: "DOSBoxKit", package: "dosbox"),
                .product(name: "ScummVMKit", package: "scummvm"),
                .product(name: "BigFishKit", package: "big-fish"),
                .product(name: "BasiliskKit", package: "basilisk"),
                .product(name: "BasiliskExecutor", package: "basilisk"),
                .product(name: "WrappModules", package: "WrappKit"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WrappBuilderToolTests",
            dependencies: ["WrappBuilderTool"],
            swiftSettings: swiftSettings
        ),
    ]
)
