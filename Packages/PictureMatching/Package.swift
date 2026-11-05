// swift-tools-version: 6.2
//
// Matching pictures: a screen's fingerprint, finding a template in a
// screenshot, and reading its text (OCR). WrappPuppeteer drives games with
// it (through PuppeteerCore, which re-exports it), and `sc puppet` names a
// game's screens and finds what to click with the same code. A package of
// its own, needing nothing but swift-log, so sc can use it without
// PuppeteerCore's SecondChanceKit and the Sentry that package fetches.

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
    name: "PictureMatching",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PictureMatching", targets: ["PictureMatching"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
    ],
    targets: [
        .target(
            name: "PictureMatching",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PictureMatchingTests",
            dependencies: ["PictureMatching"],
            swiftSettings: swiftSettings
        ),
    ]
)
