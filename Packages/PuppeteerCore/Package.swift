// swift-tools-version: 6.2
//
// WrappPuppeteer's generic utilities: capturing, finding and clicking an
// app's windows, matching pictures, and running and ending processes. Kept
// out of the executable so they can be tested (Tests/PuppeteerCoreTests),
// and generic: nothing here knows about Nancy Drew, wrapps or engines; what
// is specific to driving a game lives in WrappPuppeteer/NancyDrew/ and
// configures this through parameters (docs/testing.md#wrapppuppeteer).

import PackageDescription

/// The same settings as the app targets and SecondChanceKit (its
/// Package.swift has why).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"]),
]

let package = Package(
    name: "PuppeteerCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PuppeteerCore", targets: ["PuppeteerCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(path: "../SecondChanceKit"),
    ],
    targets: [
        .target(
            name: "PuppeteerCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SecondChanceKit", package: "SecondChanceKit"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "PuppeteerCoreTests",
            dependencies: ["PuppeteerCore"],
            swiftSettings: swiftSettings
        ),
    ]
)
