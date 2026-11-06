// swift-tools-version: 6.2
//
// The dosbox module's Swift, beside its data in Modules/dosbox/: its kit,
// what every process that handles a dosbox: path uses of it.

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
    name: "DOSBoxModule",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DOSBoxKit", targets: ["DOSBoxKit"]),
    ],
    dependencies: [
        .package(path: "../../WrappKit"),
    ],
    targets: [
        .target(
            name: "DOSBoxKit",
            dependencies: [.product(name: "WrappModules", package: "WrappKit")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "DOSBoxKitTests",
            dependencies: ["DOSBoxKit", .product(name: "WrappModules", package: "WrappKit")],
            swiftSettings: swiftSettings
        ),
    ]
)
