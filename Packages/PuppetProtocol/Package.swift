// swift-tools-version: 6.2
//
// The puppet protocol: the requests a program under test answers on its
// control sockets — the in-process helper's game-<pid>.sock (the wine
// module's InProcessHelpers/puppet_control.m) and the wrapp's own wrapp.sock
// (WrappTemplate/PuppetServer.swift) — how each is written, and how their
// replies are read. The one definition of both, used by WrappPuppeteer
// (through PuppeteerCore, which re-exports it) and by `sc puppet`. Needs
// nothing but Foundation, so sc can use it without PuppeteerCore's
// SecondChanceKit and the Sentry that package fetches.

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
    name: "PuppetProtocol",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PuppetProtocol", targets: ["PuppetProtocol"]),
    ],
    targets: [
        .target(name: "PuppetProtocol", swiftSettings: swiftSettings),
        .testTarget(
            name: "PuppetProtocolTests",
            dependencies: ["PuppetProtocol"],
            swiftSettings: swiftSettings
        ),
    ]
)
