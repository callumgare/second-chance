// swift-tools-version: 6.2
//
// What any program that builds or runs wrapps needs, with nothing of Second
// Chance's own: logging, running and watching processes, running Wine,
// reading Windows programs and MSIs, and what a wrapp holds. Its own
// package, depending only on swift-log and GameCatalog, so the builder
// (Packages/WrappBuilder), which may one day be a command-line tool of its
// own, can use it without fetching Sentry, as anything depending on the
// SecondChanceKit package does. SecondChanceKit re-exports every module
// here, so the apps import SecondChanceKit alone. AGENTS.md ("Shared code
// is a local package") has the rules.

import PackageDescription

/// The same settings as the app targets and SecondChanceKit (its
/// Package.swift has why).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "WrappKit",
    // English, as SecondChanceKit: text people see is looked up in the
    // string catalog of the app showing it.
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        // Left to Xcode to link statically, as SecondChanceKit's (its
        // Package.swift has why).
        .library(name: "WrappLogging", targets: ["WrappLogging"]),
        .library(name: "ProcessKit", targets: ["ProcessKit"]),
        .library(name: "WindowsFormats", targets: ["WindowsFormats"]),
        .library(name: "WrappFormat", targets: ["WrappFormat"]),
        .library(name: "WrappModules", targets: ["WrappModules"]),
        .library(name: "WrappModuleKit", targets: ["WrappModuleKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(path: "../GameCatalog"),
    ],
    targets: [
        // The swift-log handlers: the log store, OSLog, the JSON-lines and
        // rotating files, and the run's context.
        .target(
            name: "WrappLogging",
            dependencies: [.product(name: "Logging", package: "swift-log")],
            swiftSettings: swiftSettings
        ),
        // Running, listing and watching processes, and the Mac's load.
        .target(
            name: "ProcessKit",
            dependencies: ["WrappLogging", .product(name: "Logging", package: "swift-log")],
            swiftSettings: swiftSettings
        ),
        // Readers of Windows programs and MSI files.
        .target(
            name: "WindowsFormats",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                // What a game draws with, when its .exe can't say.
                .product(name: "GameCatalog", package: "GameCatalog"),
            ],
            swiftSettings: swiftSettings
        ),
        // The Wine library: every Wine program starts through it.
        // Modules: their ids, and the composition of them a wrapp runs.
        .target(
            name: "WrappModules",
            dependencies: [.product(name: "GameCatalog", package: "GameCatalog")],
            swiftSettings: swiftSettings
        ),
        // What a wrapp holds: its layout, settings and source.
        .target(
            name: "WrappFormat",
            dependencies: [
                "WrappModules",
                .product(name: "GameCatalog", package: "GameCatalog"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        // What a module's executor is written against, shipped or not
        // (docs/modules.md#executors): it carries out a plan's steps through
        // the context the build gives it.
        .target(
            name: "WrappModuleKit",
            dependencies: [.product(name: "Logging", package: "swift-log")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WrappKitTests",
            dependencies: [
                "WrappLogging", "ProcessKit", "WindowsFormats", "WrappFormat", "WrappModules", "WrappModuleKit",
                .product(name: "GameCatalog", package: "GameCatalog"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
