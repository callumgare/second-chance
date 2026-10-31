// swift-tools-version: 6.2
//
// The code Second Chance, the wrapps it builds (WrappTemplate) and
// WrappPuppeteer share, as a local package the Xcode project depends on.
// AGENTS.md ("Shared code is a local package") has the rules.

import PackageDescription

/// The settings every Xcode target uses, so code reads the same here as in
/// the apps: Swift 5 mode, main-actor isolation by default (everything
/// meant to run elsewhere says `nonisolated`), what Xcode's
/// SWIFT_APPROACHABLE_CONCURRENCY and
/// SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY turn on, and the
/// `/regex/` literals Xcode allows by default.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v5),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("BareSlashRegexLiterals"),
    .enableUpcomingFeature("DisableOutwardActorInference"),
    .enableUpcomingFeature("GlobalActorIsolatedTypesUsability"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("InferSendableFromCaptures"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "Shared",
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
        .package(url: "https://github.com/getsentry/sentry-cocoa", from: "9.30.2"),
    ],
    targets: [
        // Logging, Wine, Steam and the rest. No Sentry, so WrappPuppeteer
        // can use all of it.
        .target(
            name: "SecondChanceKit",
            dependencies: [
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
    ]
)
