// swift-tools-version: 6.2
//
// The wine module's Swift, beside its data in Modules/wine/ (kept apart, so
// editing Swift doesn't change the module's release): its kit, the Wine
// library every process that runs a Windows program uses, and its executor,
// which carries out the module's instructions in a build
// (docs/modules.md#executors).

import PackageDescription

/// The same settings as the app targets and the other packages
/// (SecondChanceKit's Package.swift has why).
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "WineModule",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "WineKit", targets: ["WineKit"]),
        .library(name: "WineExecutor", targets: ["WineExecutor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(path: "../../WrappKit"),
        .package(path: "../../GameCatalog"),
    ],
    targets: [
        // Running Wine programs: `Wine`, `WineCommand`, the registry, the
        // server, the desktop, drives, and winetricks.
        .target(
            name: "WineKit",
            dependencies: [
                .product(name: "WrappLogging", package: "WrappKit"),
                .product(name: "ProcessKit", package: "WrappKit"),
                .product(name: "WrappFormat", package: "WrappKit"),
                .product(name: "WrappModules", package: "WrappKit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        // WINE.DRIVES, REGISTRY, WINETRICKS, MOUNT, KEEP-THREAD-HANDLES,
        // SKIP-SYNTH-PLAYOUT, and its setup steps.
        .target(
            name: "WineExecutor",
            dependencies: [
                "WineKit",
                .product(name: "WrappModuleKit", package: "WrappKit"),
                .product(name: "WindowsFormats", package: "WrappKit"),
                .product(name: "ProcessKit", package: "WrappKit"),
                .product(name: "WrappFormat", package: "WrappKit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            resources: [.copy("Resources/winetricks")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "WineKitTests",
            dependencies: [
                "WineKit", "WineExecutor",
                .product(name: "WrappModuleKit", package: "WrappKit"),
                .product(name: "ProcessKit", package: "WrappKit"),
                .product(name: "WindowsFormats", package: "WrappKit"),
                .product(name: "WrappFormat", package: "WrappKit"),
                .product(name: "WrappLogging", package: "WrappKit"),
                .product(name: "GameCatalog", package: "GameCatalog"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
