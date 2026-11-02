// swift-tools-version: 6.2
//
// What turns a program bundle into a wrapp, kept apart from the app so it
// could one day be a command-line tool of its own: for now, loading and
// checking bundles, and what each module contributes to a build. It
// depends only on what such a tool could ship with: GameCatalog and
// WrappKit, nothing of Second Chance's own.

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
    name: "WrappBuilder",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WrappBuilder", targets: ["WrappBuilder"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams", .upToNextMinor(from: "6.2.2")),
        .package(path: "../GameCatalog"),
        .package(path: "../WrappKit"),
    ],
    targets: [
        .target(
            name: "WrappBuilder",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
                .product(name: "GameCatalog", package: "GameCatalog"),
                .product(name: "WrappModules", package: "WrappKit"),
            ],
            swiftSettings: swiftSettings,
            linkerSettings: [.linkedFramework("JavaScriptCore")]
        ),
        .testTarget(
            name: "WrappBuilderTests",
            dependencies: ["WrappBuilder"],
            swiftSettings: swiftSettings
        ),
    ]
)
