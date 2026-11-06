// swift-tools-version: 6.2
//
// The big-fish module's Swift, beside its data in Modules/big-fish/: its kit,
// what every process that handles a big-fish: path uses of it.

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
    name: "BigFishModule",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "BigFishKit", targets: ["BigFishKit"]),
    ],
    dependencies: [
        .package(path: "../../WrappKit"),
        .package(path: "../wine"),
    ],
    targets: [
        .target(
            name: "BigFishKit",
            dependencies: [
                .product(name: "WrappModules", package: "WrappKit"),
                .product(name: "WineKit", package: "wine"),
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
