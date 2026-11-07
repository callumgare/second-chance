// swift-tools-version: 6.2
//
// A dev host for Icon Lab's API (Packages/IconLab): serves it over HTTP on
// 127.0.0.1, with the page's files and the `/api/events` WebSocket, for working
// on the page in a browser. A package of its own so Hummingbird and SwiftNIO
// stay out of the app's package graph. Temporary until `sc icon-lab serve`
// (the Icon Lab plan's phase 2).

import PackageDescription

/// The same settings as the app targets and the packages
/// (Packages/SecondChanceKit/Package.swift has why).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "icon-lab-server",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "icon-lab-server", targets: ["icon-lab-server"]),
    ],
    dependencies: [
        .package(path: "../../Packages/IconLab"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.5.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.2.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    ],
    targets: [
        .executableTarget(
            name: "icon-lab-server",
            dependencies: [
                .product(name: "IconLabAPI", package: "IconLab"),
                .product(name: "IconLabKit", package: "IconLab"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
                .product(name: "NIOCore", package: "swift-nio"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
