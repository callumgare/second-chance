// swift-tools-version: 6.2
//
// The scummvm module's Swift, beside its data in Modules/scummvm/: its
// executor, which carries out SCUMMVM.KEEP-DATA (docs/modules.md#executors).

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
    name: "ScummVMModule",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScummVMExecutor", targets: ["ScummVMExecutor"]),
        // What every process that handles a scummvm: path uses of it.
        .library(name: "ScummVMKit", targets: ["ScummVMKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.15.0"),
        .package(path: "../../WrappKit"),
    ],
    targets: [
        .target(
            name: "ScummVMKit",
            dependencies: [.product(name: "WrappModules", package: "WrappKit")],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ScummVMExecutor",
            dependencies: [
                .product(name: "WrappModuleKit", package: "WrappKit"),
                .product(name: "ProcessKit", package: "WrappKit"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ScummVMExecutorTests",
            dependencies: ["ScummVMExecutor", .product(name: "WrappModuleKit", package: "WrappKit")],
            swiftSettings: swiftSettings
        ),
    ]
)
