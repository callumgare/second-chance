// swift-tools-version: 6.2
//
// The nancy-drew module's Swift, beside its data in Modules/nancy-drew/:
// its executor, which carries out NANCY-DREW.CONFIGURE-INI
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
    name: "NancyDrewModule",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NancyDrewExecutor", targets: ["NancyDrewExecutor"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(url: "https://github.com/jpsim/Yams", .upToNextMinor(from: "6.2.2")),
        .package(path: "../../WrappKit"),
    ],
    targets: [
        .target(
            name: "NancyDrewExecutor",
            dependencies: [
                .product(name: "WrappModuleKit", package: "WrappKit"),
                .product(name: "WrappFormat", package: "WrappKit"),
                .product(name: "WindowsFormats", package: "WrappKit"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "NancyDrewExecutorTests",
            dependencies: ["NancyDrewExecutor", .product(name: "WrappModuleKit", package: "WrappKit"), .product(name: "Yams", package: "Yams")],
            swiftSettings: swiftSettings
        ),
    ]
)
