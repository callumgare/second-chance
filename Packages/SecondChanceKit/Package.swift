// swift-tools-version: 6.2
//
// The code Second Chance, the wrapps it builds (WrappTemplate) and
// WrappPuppeteer share, as a local package the Xcode project depends on.
// AGENTS.md ("Shared code is a local package") has the rules.

import PackageDescription

/// Swift 6 mode, as every Xcode target is; with the settings every Xcode
/// target uses, so code means the same here as in the apps: main-actor
/// isolation by default (everything meant to run elsewhere says
/// `nonisolated`), and what Xcode's SWIFT_APPROACHABLE_CONCURRENCY and
/// SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY turn on beyond what Swift
/// 6 does by itself.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "SecondChanceKit",
    // English, so Xcode extracts the text people see (String(localized:)) for the
    // apps' string catalogs. The text is looked up in the app showing it.
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        // Left to Xcode to link statically: engines are installed into a
        // wrapp's Contents/Frameworks beside the launcher's files, where a
        // framework of ours could collide with one of theirs
        // (WrappTemplate/check-static-linking.sh checks).
        .library(name: "SecondChanceKit", targets: ["SecondChanceKit"]),
        .library(name: "SecondChanceReporting", targets: ["SecondChanceReporting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.32.0"),
        .package(path: "../GameCatalog"),
        .package(path: "../WrappKit"),
    ],
    targets: [
        // Second Chance's own shared code: the loading and log windows,
        // Steam and the rest, plus WrappKit's modules (logging, processes,
        // Wine, Windows formats, the wrapp's layout), which it re-exports.
        // No Sentry, so WrappPuppeteer can use all of it.
        .target(
            name: "SecondChanceKit",
            dependencies: [
                .product(name: "GameCatalog", package: "GameCatalog"),
                .product(name: "Logging", package: "swift-log"),
                // The generic parts, re-exported (Exports.swift).
                .product(name: "WrappLogging", package: "WrappKit"),
                .product(name: "ProcessKit", package: "WrappKit"),
                .product(name: "WindowsFormats", package: "WrappKit"),
                .product(name: "WineKit", package: "WrappKit"),
                .product(name: "WrappFormat", package: "WrappKit"),
                .product(name: "WrappModules", package: "WrappKit"),
            ],
            swiftSettings: swiftSettings
        ),
        // Failure and success reports, through Sentry. Second Chance and
        // the wrapps link it; WrappPuppeteer doesn't.
        .target(
            name: "SecondChanceReporting",
            dependencies: [
                "SecondChanceKit",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Sentry", package: "sentry-cocoa"),
            ],
            swiftSettings: swiftSettings
        ),
        // Tests of SecondChanceKit alone, which need neither app: parsers,
        // the log's line handling, process listings and the like. They run
        // with `swift test` in seconds, with no Xcode build (sc test unit
        // runs them too). Tests that need an app stay in SecondChanceTests.
        .testTarget(
            name: "SecondChanceKitTests",
            dependencies: [
                "SecondChanceKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
