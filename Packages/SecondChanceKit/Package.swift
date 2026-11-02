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
        // Left to Xcode to link statically: a wrapp's Contents/Frameworks
        // is replaced by the engine's, so a dynamic library wouldn't
        // survive (WrappTemplate/check-output-collisions.sh checks).
        .library(name: "SecondChanceKit", targets: ["SecondChanceKit"]),
        .library(name: "SecondChanceReporting", targets: ["SecondChanceReporting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.32.0"),
        .package(path: "../GameCatalog"),
    ],
    targets: [
        // Logging, Wine, Steam and the rest. No Sentry, so WrappPuppeteer
        // can use all of it.
        .target(
            name: "SecondChanceKit",
            dependencies: [
                .product(name: "GameCatalog", package: "GameCatalog"),
                .product(name: "Logging", package: "swift-log"),
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
