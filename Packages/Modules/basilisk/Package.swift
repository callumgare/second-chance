// swift-tools-version: 6.2
//
// The basilisk module's Swift, beside its data in Modules/basilisk/: its
// executor, which carries out BASILISK.SETUP and CDROM (docs/modules.md#executors),
// and its kit, what every process that handles a basilisk: path uses of it.

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
    name: "BasiliskModule",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BasiliskExecutor", targets: ["BasiliskExecutor"]),
        .library(name: "BasiliskKit", targets: ["BasiliskKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(path: "../../WrappKit"),
    ],
    targets: [
        .target(
            name: "BasiliskKit",
            dependencies: [.product(name: "WrappModules", package: "WrappKit")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "BasiliskExecutor",
            dependencies: [
                .product(name: "WrappModuleKit", package: "WrappKit"),
                .product(name: "ProcessKit", package: "WrappKit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "BasiliskTests",
            dependencies: ["BasiliskExecutor", "BasiliskKit", .product(name: "WrappModuleKit", package: "WrappKit"),
                           .product(name: "WrappModules", package: "WrappKit")],
            swiftSettings: swiftSettings
        ),
    ]
)
