// swift-tools-version: 6.2
//
// Icon Lab: designing the icons the program bundles ship. `IconLabKit` is the
// engine (catalogues and sources, gathering, analysis, parts, treatments,
// rendering, documents, jobs); `IconLabAPI` is its API (docs/api.md) with no
// web server in it, so the app can answer the page's requests itself and a
// dev server (Tools/icon-lab/server) can serve the same API over HTTP. The
// page (Tools/icon-lab/web) is built into IconLabAPI's resources by
// `sc icon-lab build`, so a Mac building the app needs no Node.
// Hummingbird and SwiftNIO stay out of this package: the app must never
// fetch them. README.md has where things are.

import PackageDescription

/// The same settings as the app targets and the other packages
/// (Packages/SecondChanceKit/Package.swift has why).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "IconLab",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "IconLabKit", targets: ["IconLabKit"]),
        .library(name: "IconLabAPI", targets: ["IconLabAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(path: "../WrappKit"),
    ],
    targets: [
        // The engine.
        .target(
            name: "IconLabKit",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                // Running ictool, icon-extract, ditto and the rest off the main thread.
                .product(name: "ProcessKit", package: "WrappKit"),
            ],
            swiftSettings: swiftSettings
        ),
        // The API (docs/api.md): requests in, responses and events out, for any host.
        .target(
            name: "IconLabAPI",
            dependencies: [
                "IconLabKit",
                .product(name: "Logging", package: "swift-log"),
            ],
            // The built page; source.sha256 is the hash of the source it was built from (WebBuildTests).
            exclude: ["Resources/source.sha256"],
            resources: [.copy("Resources/web")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "IconLabKitTests",
            dependencies: ["IconLabKit", "IconLabAPI", .product(name: "Logging", package: "swift-log")],
            // Recorded answers, read by path (CatalogTests.fixture).
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings
        ),
    ]
)
