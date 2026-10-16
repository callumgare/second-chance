import Foundation

/// The one place xcodebuild is run from.
///
/// Every invocation passes `ONLY_ACTIVE_ARCH=NO`, and that is load-bearing:
/// WrappTemplate is `ARCHS = x86_64` (Wine is 32-bit) while everything else is
/// universal, so an active-arch-only build on Apple Silicon emits swift-log
/// for arm64 alone and WrappTemplate then fails to resolve or link `Logging`
/// — which surfaces as a failing *test* run when it is really a build failure.
struct Xcode {
    let session: Session
    var repo: Repo { session.repo }
    var ui: UI { session.ui }

    static let scheme = "SecondChance"

    /// Tests run on the host architecture only. Without pinning, xcodebuild
    /// matches both arm64 and x86_64 and launches two test runners in
    /// parallel, doubling Wine installs.
    static var destination: String {
        #if arch(arm64)
        "platform=macOS,arch=arm64"
        #else
        "platform=macOS,arch=x86_64"
        #endif
    }

    private func arguments(configuration: String) -> [String] {
        [
            "-project", repo.project.path,
            "-scheme", Self.scheme,
            "-configuration", configuration,
            "-derivedDataPath", repo.derivedData.path,
            "ONLY_ACTIVE_ARCH=NO",
        ]
    }

    private static let environment: [String: String?] = ["NSUnbufferedIO": "YES"]

    /// Build Second Chance.app (and WrappTemplate.app inside it, WrappPuppeteer
    /// and the tests' dependencies) incrementally.
    func buildApp(configuration: String = "Debug") async throws {
        try Proc.require("xcbeautify", brew: "xcbeautify")
        let args = arguments(configuration: configuration) + ["build"]
        try await ui.logStep(
            configuration == "Debug" ? "Build Second Chance" : "Build Second Chance (\(configuration))",
            log: "build-\(configuration.lowercased())", formatting: .xcbeautify,
            success: configuration == "Debug" ? "Built Second Chance" : "Built Second Chance (\(configuration))"
        ) { sink in
            try await Proc.stream("xcodebuild", args, env: Self.environment, cwd: repo.root) { await sink.line($0) }
        }
    }

    /// The app build every command that needs the app starts with, unless
    /// `--skip-app-build` says to use what's already there.
    func ensureAppBuild(_ options: AppBuildOptions) async throws {
        if options.skipAppBuild {
            try repo.requireDebugApp()
            ui.detail("Using the existing app build (--skip-app-build).")
        } else {
            try await buildApp()
        }
    }

    private var testArguments: [String] {
        ["-scheme", Self.scheme, "-destination", Self.destination, "-derivedDataPath", repo.derivedData.path]
    }

    /// Build the app and the test bundle.
    func buildForTesting() async throws {
        try Proc.require("xcbeautify", brew: "xcbeautify")
        let args = ["build-for-testing"] + testArguments + ["ONLY_ACTIVE_ARCH=NO"]
        try await ui.logStep("Build for testing", log: "build-for-testing", formatting: .xcbeautify, success: "Built for testing") { sink in
            try await Proc.stream("xcodebuild", args, env: Self.environment, cwd: repo.root) { await sink.line($0) }
        }
    }

    func ensureTestBuild(_ options: AppBuildOptions) async throws {
        if options.skipAppBuild {
            guard FileManager.default.isDirectory(repo.testBundle) else {
                throw SCError(
                    "The existing build has no tests in it (\(repo.display(repo.testBundle)) is missing).",
                    hints: ["A plain app build (sc app build) removes them. Drop --skip-app-build to build for testing."]
                )
            }
            ui.detail("Using the existing test build (--skip-app-build).")
        } else {
            try await buildForTesting()
        }
    }

    /// How many tests a selection would run, from `-enumerate-tests`.
    func countTests(selection: [String]) async throws -> Int? {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sc-enumerate-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: output) }
        let args = ["test-without-building"] + testArguments + selection + [
            "-enumerate-tests", "-test-enumeration-format", "json",
            "-test-enumeration-style", "hierarchical", "-test-enumeration-output-path", output.path,
        ]
        let result = try await Proc.collect("xcodebuild", args, env: Self.environment, cwd: repo.root)
        guard result.succeeded, let data = try? Data(contentsOf: output),
              let count = TestEnumeration.countEnabledTests(json: data), count > 0 else { return nil }
        return count
    }

    /// Run tests from an existing test build. Returns xcodebuild's status;
    /// the caller decides how to present the result. Raw lines go to `sink`.
    func runTests(
        selection: [String],
        environment: [String: String],
        resultBundle: URL,
        sink: LogSink
    ) async throws -> Int32 {
        let args = ["test-without-building"] + testArguments + ["-resultBundlePath", resultBundle.path] + selection
        var env = Self.environment
        for (key, value) in environment { env[key] = value }
        return try await Proc.stream("xcodebuild", args, env: env, cwd: repo.root) { await sink.line($0) }
    }
}
