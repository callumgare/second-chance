import Foundation

/// What Icon Lab uses from outside itself, which the host finds and passes in: the programs it runs and the places
/// it offers in the file browser. Any of them may be missing; what needs it then says so.
nonisolated public struct LabTools: Sendable {
    /// `icon-extract` (Packages/WrappKit, docs/program-images.md), for "Add from files". `$ICON_EXTRACT` overrides it.
    public var iconExtract: String?
    /// Xcode's Icon Composer renderer, for Final renders.
    public var ictool: String?
    /// Where built wrapps are (a checkout's `built-apps/`), offered as a place in the file browser.
    public var builtApps: URL?

    public init(iconExtract: String? = nil, ictool: String? = nil, builtApps: URL? = nil) {
        self.iconExtract = iconExtract
        self.ictool = ictool
        self.builtApps = builtApps
    }

    /// Where Xcode keeps Icon Composer's renderer.
    public static let xcodeICTool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"

    /// The tools as a checkout has them: `icon-extract` built in its WrappKit package (or in its `icon-lab`
    /// worktree's), Xcode's `ictool` if it's installed, and its `built-apps/`.
    public static func inCheckout(_ checkout: URL) -> LabTools {
        let fm = FileManager.default
        var extract: String?
        search: for root in [checkout.appendingPathComponent(".claude/worktrees/icon-lab"), checkout] {
            for config in ["release", "debug"] {
                let p = root.appendingPathComponent("Packages/WrappKit/.build/\(config)/icon-extract").path
                if fm.isExecutableFile(atPath: p) { extract = p; break search }
            }
        }
        return LabTools(iconExtract: extract, ictool: fm.isExecutableFile(atPath: xcodeICTool) ? xcodeICTool : nil,
                        builtApps: checkout.appendingPathComponent("built-apps"))
    }
}
