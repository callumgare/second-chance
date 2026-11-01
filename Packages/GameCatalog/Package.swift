// swift-tools-version: 6.2
//
// Every Nancy Drew game Second Chance knows, and how each is run: shared by
// the app, the wrapps, WrappPuppeteer (through SecondChanceKit, which
// depends on it) and the developer CLI in Tools/sc. A package of its own,
// with nothing but Foundation, so sc can use it without fetching what
// SecondChanceKit needs. AGENTS.md ("Shared code is a local package") has
// the rules.

import PackageDescription

let package = Package(
    name: "GameCatalog",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GameCatalog", targets: ["GameCatalog"]),
    ],
    targets: [
        // The same settings as SecondChanceKit's (see its Package.swift).
        .target(
            name: "GameCatalog",
            swiftSettings: [
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
        ),
    ]
)
