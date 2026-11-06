import ArgumentParser
import CoreGraphics
import Foundation
import ImageIO
import PictureMatching
import PuppetProtocol
import WrappBuilder

// `sc puppet screen`, `name` and `expect`, and the locators `do` takes:
// naming what's on a puppet session's screen with a bundle's needles
// (docs/testing.md#needles), with WrappPuppeteer's own matching
// (Packages/PictureMatching). See docs/dev-cli.md#puppet-sessions.

// MARK: Commands

/// Where a command's needles come from, beyond the session's bundle.
/// The needles' source beyond the session's own: the bundle is the shared
/// `--bundle` (`GlobalOptions`), a shipped bundle's id or a draft's folder,
/// remembered for the session.
struct PuppetNeedleOptions: ParsableArguments {
    @Option(help: ArgumentHelp("Another folder of needles, looked in first.", valueName: "folder"))
    var needles: String?
}

struct PuppetScreenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screen",
        abstract: "Which of the bundle's needles the game's screen matches, and how sure.",
        discussion: """
        The needles are the session's own (made by `sc puppet name`), then the \
        bundle's tests/needles, then those of the module its test scenario is in: \
        the bundle given with --bundle, or the wrapp's own. Each tag is a screen's \
        name; `screen` needles are judged by fingerprint distance (a match at most \
        0.08), `region` ones by template correlation, `text` ones by OCR.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @OptionGroup var source: PuppetNeedleOptions

    @Option(help: "How many tags at most.") var max: Int = 12

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        puppet.touch()
        let library = try PuppetNeedles.library(puppet, options: source, repo: session.repo.root)
        guard !library.needles.isEmpty else { throw PuppetNeedles.noNeedles(puppet, library) }
        let frame = try PuppetFrame.capture(puppet)
        let identified = PuppetScreens.identify(frame, needles: library.needles)
        session.ui.line("screen: " + (identified.name ?? "?"))
        for line in identified.report(max: max) { session.ui.line(line) }
        session.ui.detail("needles: \(library.needles.count) from \(library.sources.joined(separator: ", "))")
    }
}

struct PuppetNameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "name",
        abstract: "Cut a needle from the game's screen, in the bundles' format: a screen, a part of it (--region), or its text (--text).",
        discussion: """
        With neither option, a `screen` needle: the whole picture, its dark bars \
        trimmed, as WrappPuppeteer's splash references are. --region x,y,w,h (in \
        points, as `text` gives them) makes a `region` needle of that part, searched \
        for around where it is now and sized to the window; with --text, a `text` \
        needle of the lines read there. Written to --out (default: the session's \
        needles, which `screen` reads first), so a port's session grows its \
        integration test's needles: copy them into the bundle's tests/needles and \
        say in each file's comment what it shows.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String
    @Argument(help: "The tag: the screen's name, which a scenario's handler waits for (`running`, `title`, `quit`).") var tag: String

    @Option(help: ArgumentHelp("A part of the window, in points.", valueName: "x,y,w,h")) var region: String?
    @Flag(help: "A text needle: the lines OCR reads (in --region, or anywhere).") var text = false
    @Option(help: ArgumentHelp("The folder to write it to (default: the session's needles).", valueName: "folder")) var out: String?
    @Option(name: .customLong("as"), help: ArgumentHelp("The needle's file name, without .yaml (default: the tag).", valueName: "name"))
    var fileName: String?
    @Flag(help: "Replace a needle of that name.") var force = false

    func validate() throws {
        guard PuppetSession.validName(tag) else { throw ValidationError("A tag is lower-case letters, digits and dashes.") }
        if let region, PuppetFrame.rect(region) == nil { throw ValidationError("--region takes x,y,w,h in points.") }
        if let fileName, !PuppetSession.validName(fileName) { throw ValidationError("--as is lower-case letters, digits and dashes.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        puppet.touch()
        let folder = out.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? puppet.needlesFolder
        let base = fileName ?? tag
        let yaml = folder.appendingPathComponent(base + ".yaml"), png = folder.appendingPathComponent(base + ".png")
        if !force, FileManager.default.fileExists(atPath: yaml.path) {
            throw SCError("\(yaml.path) exists.", hints: ["Another name: --as \(base)-2", "Or replace it: --force"])
        }
        let frame = try PuppetFrame.capture(puppet)
        let cut = try NeedleCut.make(tag: tag, from: frame, region: region.flatMap(PuppetFrame.rect), text: text,
                                     origin: "\(name)'s screen at \(ScreenLease.clock(Date()))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try cut.yaml.write(to: yaml, atomically: true, encoding: .utf8)
        if let image = cut.image {
            try PuppetFrame.write(image, to: png)
        } else if force {
            try? FileManager.default.removeItem(at: png)
        }
        session.ui.line("\(cut.kind) needle \(base), tag \(tag): \(cut.summary)")
        if let warning = cut.warning { session.ui.warning("\(warning)") }
        // Checked against the frame it was cut from, as `screen` would.
        let needle = try NeedleLibrary.needle(at: yaml)
        for warning in needle.searchWarnings { session.ui.warning("\(warning) (sc bundle check says so too)") }
        let check = PuppetScreens.identify(frame, needles: [needle])
        session.ui.line("matches this screen: " + (check.results.first.map { ($0.found ? "yes, " : "no, ") + $0.detail } ?? "?"))
        session.ui.line(yaml.path + (cut.image == nil ? "" : "  (and \(png.lastPathComponent))"))
        session.ui.line("fetch: " + PuppetShotCommand.fetchLine(yaml) + (cut.image == nil ? "" : "; " + PuppetShotCommand.fetchLine(png)))
    }
}

struct PuppetExpectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "expect",
        abstract: "Check the screen is a named one, or shows some text, trying again until it does or time runs out.",
        discussion: """
        Exit 0 once it is; 3 when it isn't by --timeout, keeping the last shot and \
        saying the closest thing to it that was there; 4 if the program ended.
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument var name: String

    @Option(help: ArgumentHelp("A screen's name: a tag of the bundle's needles.", valueName: "tag")) var screen: String?
    @Option(help: ArgumentHelp("Text that shows (OCR, ignoring case).", valueName: "text")) var text: String?
    @Option(help: "Give up after this many seconds.") var timeout: Double = 20

    @OptionGroup var source: PuppetNeedleOptions

    func validate() throws {
        guard (screen == nil) != (text == nil) else { throw ValidationError("Expect one thing: --screen <tag> or --text <text>.") }
    }

    func run() async throws {
        let session = try Session.start(global)
        let puppet = try PuppetSession.load(name)
        guard puppet.isRunning else { throw SCError("\(name) has stopped: \(puppet.stopReason ?? "?").", exitCode: 4) }
        var needles: [Needle] = []
        if let screen {
            let library = try PuppetNeedles.library(puppet, options: source, repo: session.repo.root)
            guard !library.tagged(screen).isEmpty else {
                let tags = Set(library.needles.flatMap(\.spec.tags)).sorted()
                throw SCError("No needle is tagged \(screen).",
                              hints: [tags.isEmpty ? "No needles at all: name one (sc puppet name \(name) \(screen))"
                                                   : "The tags there are: \(tags.joined(separator: ", "))"])
            }
            needles = library.needles
        }
        let started = Date()
        var last: (frame: PuppetFrame, identified: IdentifiedScreen?)?
        repeat {
            puppet.touch()
            guard puppet.wrappPID.map({ kill($0, 0) == 0 }) ?? false else {
                session.ui.line("the program ended after \(PuppetWaitCommand.seconds(started))")
                throw ExitCode(4)
            }
            let frame = try PuppetFrame.capture(puppet)
            if let screen {
                let identified = PuppetScreens.identify(frame, needles: needles)
                if let found = identified.found(screen) {
                    session.ui.line("screen: \(screen) after \(PuppetWaitCommand.seconds(started)) (\(found.needle.id): \(found.detail))")
                    return
                }
                last = (frame, identified)
            } else if let wanted = text {
                if let line = frame.lines.first(where: { TextRecognizer.lineContains($0.text, wanted) }) {
                    session.ui.line("\"\(line.text)\" at \(PuppetFrame.describe(line.box)) after \(PuppetWaitCommand.seconds(started))")
                    return
                }
                last = (frame, nil)
            }
            if Date().timeIntervalSince(started) < timeout { try await Task.sleep(for: .seconds(1)) }
        } while Date().timeIntervalSince(started) < timeout

        guard let last else { throw ExitCode(3) }
        let kept = puppet.nextShot(suffix: "expect")
        try PuppetFrame.write(last.frame.image, to: kept)
        if let screen, let identified = last.identified {
            session.ui.line("not \(screen) after \(Int(timeout)) s; the screen is " + (identified.name ?? "none the needles know"))
            if let nearest = identified.nearest(screen) { session.ui.line("closest: \(nearest.needle.id): \(nearest.detail)") }
        } else if let wanted = text {
            session.ui.line("no \"\(wanted)\" after \(Int(timeout)) s")
            if let nearest = last.frame.lines.max(by: { Similarity.of($0.text, wanted) < Similarity.of($1.text, wanted) }) {
                session.ui.line("closest: \"\(nearest.text)\" at \(PuppetFrame.describe(nearest.box))")
            } else {
                session.ui.line("closest: none (no text read)")
            }
        }
        session.ui.line("kept: \(kept.path)")
        session.ui.line("fetch: " + PuppetShotCommand.fetchLine(kept))
        throw ExitCode(3)
    }
}

// MARK: Locators

/// What `do` acts on, found at the moment of acting rather than given as a
/// point: some text, or a needle. Strict: two matches is an error listing
/// both, unless `--nth` picks one.
struct PuppetLocator: ParsableArguments {
    @Option(name: .customLong("text"), help: ArgumentHelp("Act on this text (OCR; a line that is it exactly, ignoring case, else one holding it).",
                                                         valueName: "text"))
    var locateText: String?
    @Option(help: ArgumentHelp("Act on where this needle is found: its .yaml (a .png beside it for an image), or a .png alone.",
                               valueName: "file"))
    var needle: String?
    @Option(help: "Of several matches, the nth (1 is the first, reading top to bottom, left to right).") var nth: Int?
    @Option(help: ArgumentHelp("Only matches in this part of the window, in points.", valueName: "x,y,w,h")) var within: String?
    @Option(help: "How long to look for it before giving up, in seconds.") var findTimeout: Double = 5

    var isSet: Bool { locateText != nil || needle != nil }

    func validate() throws {
        if locateText != nil, needle != nil { throw ValidationError("Locate by --text or --needle, not both.") }
        if let nth, nth < 1 { throw ValidationError("--nth counts from 1.") }
        if let within, PuppetFrame.rect(within) == nil { throw ValidationError("--within takes x,y,w,h in points.") }
        if !isSet, nth != nil || within != nil { throw ValidationError("--nth and --within go with --text or --needle.") }
    }

    /// A located action's arguments: the point to act at, and how it was
    /// found, for the reply.
    func locate(_ verb: String, _ arguments: [String], puppet: PuppetSession) async throws -> (arguments: [String], description: String)? {
        guard isSet else { return nil }
        guard ["click", "move", "down", "up"].contains(verb), arguments.isEmpty else {
            throw ValidationError("--text and --needle locate a click, move, down or up, in place of its x and y.")
        }
        let target = try await resolve(puppet)
        return ([String(format: "%.0f", target.point.x), String(format: "%.0f", target.point.y)], target.description)
    }

    /// Looks until exactly one match (or the nth) shows, or `find` runs out.
    func resolve(_ puppet: PuppetSession) async throws -> PuppetTarget {
        let loaded = try needle.map(PuppetLocator.load)
        let started = Date()
        while true {
            let frame = try PuppetFrame.capture(puppet)
            var found = candidates(in: frame, needle: loaded)
            if let within = within.flatMap(PuppetFrame.rect) {
                found = found.filter { within.contains(CGPoint(x: $0.rect.midX, y: $0.rect.midY)) }
            }
            if let target = try Self.pick(found, nth: nth, what: what) { return target }
            if Date().timeIntervalSince(started) >= findTimeout {
                let seen = nth.map { "\(found.count) match\(found.count == 1 ? "" : "es"), fewer than \($0)," } ?? "nothing"
                var hints = ["What's there: sc puppet text \(puppet.name)"]
                if let wanted = locateText,
                   let nearest = frame.lines.max(by: { Similarity.of($0.text, wanted) < Similarity.of($1.text, wanted) }) {
                    hints.insert("Closest: \"\(nearest.text)\" at \(PuppetFrame.describe(nearest.box))", at: 0)
                }
                throw SCError("Found \(seen) for \(what) in \(Int(findTimeout)) s.", hints: hints, exitCode: 3)
            }
            try await Task.sleep(for: .seconds(0.7))
        }
    }

    /// The one target among `found`, or the nth reading top to bottom and
    /// left to right; nil while there are too few. Two with no `nth` is an
    /// error listing them (exit 5).
    static func pick(_ found: [PuppetTarget], nth: Int?, what: String) throws -> PuppetTarget? {
        let ordered = found.sorted { ($0.rect.minY.rounded(), $0.rect.minX) < ($1.rect.minY.rounded(), $1.rect.minX) }
        if let nth { return ordered.count >= nth ? ordered[nth - 1] : nil }
        guard ordered.count <= 1 else {
            throw SCError("\(ordered.count) matches for \(what):\n" + ordered.enumerated().map { "  \($0 + 1). \($1.description)" }.joined(separator: "\n"),
                          hints: ["Pick one: --nth <n>, or narrow the search: --within x,y,w,h"], exitCode: 5)
        }
        return ordered.first
    }

    private var what: String { locateText.map { "\"\($0)\"" } ?? needle.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?" }

    /// A needle file, or a bare image to find at its own size.
    private static func load(_ path: String) throws -> LocatorNeedle {
        let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: file.path) else { throw SCError("No needle at \(file.path).") }
        if file.pathExtension == "png" {
            let yaml = file.deletingPathExtension().appendingPathExtension("yaml")
            if FileManager.default.fileExists(atPath: yaml.path) { return .needle(try NeedleLibrary.needle(at: yaml)) }
            return .image(file)
        }
        return .needle(try NeedleLibrary.needle(at: file))
    }

    private func candidates(in frame: PuppetFrame, needle: LocatorNeedle?) -> [PuppetTarget] {
        if let wanted = locateText {
            let containing = frame.lines.filter { TextRecognizer.lineContains($0.text, wanted) }
            let exact = containing.filter { $0.text.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(wanted) == .orderedSame }
            return (exact.isEmpty ? containing : exact).map { line in
                PuppetTarget(rect: line.box, point: CGPoint(x: line.box.midX, y: line.box.midY),
                             description: "\"\(line.text)\" at \(PuppetFrame.describe(line.box))")
            }
        }
        switch needle {
        case .image(let file):
            return TemplateMatcher.matches(file.path, in: frame.path.path, limit: max(2, nth ?? 1)).map { match in
                let rect = frame.points(match.rect)
                return PuppetTarget(rect: rect, point: CGPoint(x: rect.midX, y: rect.midY),
                                    description: "\(file.lastPathComponent) at \(PuppetFrame.describe(rect)), confidence \(String(format: "%.2f", match.confidence))")
            }
        case .needle(let needle):
            return PuppetScreens.locations(of: needle, in: frame, limit: max(2, nth ?? 1))
        case nil:
            return []
        }
    }
}

private enum LocatorNeedle {
    case needle(Needle)
    case image(URL)
}

/// Something found to act on: where it is and the point to act at, in
/// window points.
struct PuppetTarget {
    let rect: CGRect
    let point: CGPoint
    let description: String
}

// MARK: Matching

/// One needle judged against a frame.
struct NeedleResult {
    let needle: Needle
    let found: Bool
    /// Where, in window points, when found.
    let rect: CGRect?
    /// How it was judged: the distance, confidence or text.
    let detail: String
    /// How near it came, 0…1, for ordering near misses; a match is ≥ 0.5.
    let score: Double
}

/// A frame's needles: which matched, and so which tags (screens) it is.
struct IdentifiedScreen {
    let results: [NeedleResult]

    /// Tags matched, surest first: a screen needle's, then text, then region.
    var tags: [String] {
        var seen: [String] = []
        let order: [Needle.Kind] = [.screen, .text, .region]
        for result in results.filter(\.found).sorted(by: { (order.firstIndex(of: $0.needle.spec.kind) ?? 0, -$0.score)
                                                       < (order.firstIndex(of: $1.needle.spec.kind) ?? 0, -$1.score) }) {
            for tag in result.needle.spec.tags where !seen.contains(tag) { seen.append(tag) }
        }
        return seen
    }

    /// The screen's name: its tags, or nil when no needle matched.
    var name: String? { tags.isEmpty ? nil : tags.joined(separator: ", ") }

    func found(_ tag: String) -> NeedleResult? {
        results.filter { $0.found && $0.needle.spec.tags.contains(tag) }.max { $0.score < $1.score }
    }

    /// The needle of `tag` that came nearest.
    func nearest(_ tag: String) -> NeedleResult? {
        results.filter { $0.needle.spec.tags.contains(tag) }.max { $0.score < $1.score }
    }

    /// A line a tag: the matched first, with the needle that matched; then
    /// the rest, with their nearest needle.
    func report(max: Int) -> [String] {
        let all = Set(results.flatMap(\.needle.spec.tags))
        let matched = tags
        let rest = all.subtracting(matched).sorted { (nearest($0)?.score ?? 0) > (nearest($1)?.score ?? 0) }
        var lines = matched.compactMap { tag in found(tag).map { "  \(tag): yes, \($0.needle.id): \($0.detail)" } }
        lines += rest.compactMap { tag in nearest(tag).map { "  \(tag): no, nearest \($0.needle.id): \($0.detail)" } }
        if lines.count > max { return Array(lines.prefix(max)) + ["  … \(lines.count - max) more tags (--max)"] }
        return lines
    }
}

enum PuppetScreens {
    /// Every needle judged against the frame, as WrappPuppeteer judges them
    /// (`SplashScreen`, `MainMenuScreen`): a screen needle by its
    /// fingerprint's distance, a region needle by the template search, a
    /// text needle by its strings in OCR's lines, the first found winning.
    static func identify(_ frame: PuppetFrame, needles: [Needle]) -> IdentifiedScreen {
        let fingerprint = needles.contains { $0.spec.kind == .screen } ? ImageFingerprint(image: frame.image) : nil
        return IdentifiedScreen(results: needles.map { needle in
            switch needle.spec.kind {
            case .screen: screen(needle, fingerprint, frame)
            case .region: region(needle, frame)
            case .text: text(needle, frame)
            }
        })
    }

    private static func screen(_ needle: Needle, _ fingerprint: ImageFingerprint?, _ frame: PuppetFrame) -> NeedleResult {
        let limit = Double(ImageFingerprint.sameScreenDistance)
        guard let fingerprint else { return NeedleResult(needle: needle, found: false, rect: nil, detail: "the screen is blank", score: 0) }
        guard let path = needle.image?.path, let reference = ImageFingerprint(imageAt: path, trimmingMargins: false) else {
            return NeedleResult(needle: needle, found: false, rect: nil, detail: "its picture is blank or unreadable", score: 0)
        }
        let distance = Double(fingerprint.distance(to: reference))
        let content = frame.points(fraction: fingerprint.contentRect)
        return NeedleResult(needle: needle, found: distance <= limit, rect: content,
                            detail: String(format: "distance %.3f (a match is at most %.2f)", distance, limit),
                            score: Swift.max(0, 1 - distance / (2 * limit)))
    }

    private static func region(_ needle: Needle, _ frame: PuppetFrame) -> NeedleResult {
        let options = matchOptions(needle)
        guard let path = needle.image?.path, let best = TemplateMatcher.best(path, in: frame.path.path, options: options) else {
            return NeedleResult(needle: needle, found: false, rect: nil, detail: "no candidate anywhere it's searched for", score: 0)
        }
        let rect = frame.points(best.rect)
        return NeedleResult(needle: needle, found: best.isMatch, rect: best.isMatch ? rect : nil,
                            detail: String(format: "confidence %.2f at %@ (a match is at least %.2f)", best.confidence,
                                           PuppetFrame.describe(rect), options.minConfidence * 0.9),
                            score: Double(Swift.max(0, best.confidence)))
    }

    private static func text(_ needle: Needle, _ frame: PuppetFrame) -> NeedleResult {
        let strings = needle.spec.text?.strings ?? []
        for string in strings {
            if let line = frame.lines.first(where: { TextRecognizer.lineContains($0.text, string) }) {
                return NeedleResult(needle: needle, found: true, rect: line.box,
                                    detail: "\"\(string)\" in \"\(line.text)\" at \(PuppetFrame.describe(line.box))", score: 1)
            }
        }
        let nearest = frame.lines.flatMap { line in strings.map { (line, $0, Similarity.of(line.text, $0)) } }.max { $0.2 < $1.2 }
        guard let nearest else {
            return NeedleResult(needle: needle, found: false, rect: nil, detail: "no text read; looks for \(Self.quoted(strings))", score: 0)
        }
        return NeedleResult(needle: needle, found: false, rect: nil,
                            detail: "nearest line \"\(nearest.0.text)\" to \"\(nearest.1)\"; looks for \(Self.quoted(strings))",
                            score: nearest.2 * 0.49)
    }

    private static func quoted(_ strings: [String]) -> String { strings.map { "\"\($0)\"" }.joined(separator: ", ") }

    /// Where a needle is on the frame, each place it's found (up to `limit`
    /// for an image), with its click point: for acting on it.
    static func locations(of needle: Needle, in frame: PuppetFrame, limit: Int) -> [PuppetTarget] {
        switch needle.spec.kind {
        case .screen:
            let result = screen(needle, ImageFingerprint(image: frame.image), frame)
            guard result.found, let rect = result.rect else { return [] }
            return [PuppetTarget(rect: rect, point: needle.clickPoint(in: rect), description: "\(needle.id) (\(result.detail))")]
        case .region:
            guard let path = needle.image?.path else { return [] }
            return TemplateMatcher.matches(path, in: frame.path.path, options: matchOptions(needle), limit: limit).map { match in
                let rect = frame.points(match.rect)
                return PuppetTarget(rect: rect, point: needle.clickPoint(in: rect),
                                    description: "\(needle.id) at \(PuppetFrame.describe(rect)), confidence \(String(format: "%.2f", match.confidence))")
            }
        case .text:
            // The first of its strings found, as a scenario takes it; every
            // line holding that one.
            for string in needle.spec.text?.strings ?? [] {
                let lines = frame.lines.filter { TextRecognizer.lineContains($0.text, string) }
                if !lines.isEmpty {
                    return lines.map { PuppetTarget(rect: $0.box, point: needle.clickPoint(in: $0.box),
                                                    description: "\(needle.id): \"\($0.text)\" at \(PuppetFrame.describe($0.box))") }
                }
            }
            return []
        }
    }

    /// A `region` needle's search, as the template matcher takes it: what
    /// WrappPuppeteer's `MainMenuScreen.matchOptions` makes of it.
    static func matchOptions(_ needle: Needle) -> TemplateMatchOptions {
        let region = needle.spec.region
        return TemplateMatchOptions(regionSearch: region?.search?.cgRect, heightFraction: region?.heightFraction,
                                    scales: region?.scales, grayscale: region?.grayscale)
    }

    /// The screen's name for an action's reply: nil when there are no
    /// needles to name it by, "?" when none matched.
    static func replyName(_ puppet: PuppetSession, repo: URL) -> String? {
        guard let library = try? PuppetNeedles.library(puppet, bundle: nil, needles: nil, repo: repo), !library.needles.isEmpty,
              let frame = try? PuppetFrame.capture(puppet) else { return nil }
        return identify(frame, needles: library.needles).name ?? "?"
    }
}

/// How alike two strings are, 0…1, ignoring case: for the closest line to
/// text that wasn't found.
enum Similarity {
    static func of(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        guard !x.isEmpty || !y.isEmpty else { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var previous = Array(0...y.count)
        for i in 1...x.count {
            var current = [i] + [Int](repeating: 0, count: y.count)
            for j in 1...y.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }
}

// MARK: Needles

/// The needles a session's screens are named by.
enum PuppetNeedles {
    struct Library {
        let needles: [Needle]
        /// The folders they came from, nearest first, for the reply.
        let sources: [String]
        let bundle: String?

        func tagged(_ tag: String) -> [Needle] { needles.filter { $0.spec.tags.contains(tag) } }
    }

    /// `options.needles`, the session's own, then the bundle's and its
    /// scenario's module's: a nearer needle replacing a farther one of the
    /// same id, as a test's do. A bundle given is remembered for the
    /// session.
    static func library(_ puppet: PuppetSession, options: PuppetNeedleOptions, repo: URL) throws -> Library {
        try library(puppet, bundle: ExtraBundleOptions.ids.first, needles: options.needles, repo: repo)
    }

    static func library(_ puppet: PuppetSession, bundle given: String?, needles extra: String?, repo: URL) throws -> Library {
        if let given {
            guard FileManager.default.fileExists(atPath: bundleFolder(given, repo: repo).appendingPathComponent("manifest.yaml").path) else {
                throw SCError("No program bundle \(given) in \(repo.appendingPathComponent("Bundles").path).")
            }
            // Into the session as it is now on disk, which the server only
            // ever changes its own fields of (`saveServerState`).
            var stored = try PuppetSession.load(puppet.name)
            stored.bundle = given
            try stored.save()
        }
        let bundle = given ?? bundleID(of: puppet)
        var folders: [URL] = []
        if let extra { folders.append(URL(fileURLWithPath: (extra as NSString).expandingTildeInPath)) }
        folders.append(puppet.needlesFolder)
        if let bundle {
            let folder = bundleFolder(bundle, repo: repo)
            folders.append(folder.appendingPathComponent("tests/needles"))
            let modules = repo.appendingPathComponent("Modules")
            if let module = scenarioModule(folder, modules: modules) {
                folders.append(modules.appendingPathComponent(module).appendingPathComponent("needles"))
            }
        }
        let library = try NeedleLibrary.load(folders)
        let used = folders.filter { FileManager.default.fileExists(atPath: $0.path) }
        return Library(needles: library.needles, sources: used.map { relative($0, to: repo) }, bundle: bundle)
    }

    static func noNeedles(_ puppet: PuppetSession, _ library: Library) -> SCError {
        SCError("No needles to name \(puppet.name)'s screen by\(library.bundle.map { " (bundle \($0))" } ?? "").",
                hints: [library.bundle == nil ? "Name its bundle: --bundle <id or folder>" : "Its bundle has no tests/needles yet",
                        "Cut one from this screen: sc puppet name \(puppet.name) <tag>"])
    }

    /// The folder of bundle `id`: a draft's `--bundle` named, else the shipped one's.
    static func bundleFolder(_ id: String, repo: URL) -> URL {
        ExtraBundles.folder(of: id, shippedRoot: repo.appendingPathComponent("Bundles"))
    }

    /// The bundle remembered for the session, else its wrapp's
    /// (`Contents/Resources/WrappLock.json`).
    static func bundleID(of puppet: PuppetSession) -> String? {
        if let remembered = puppet.bundle, !remembered.isEmpty { return remembered }
        let lock = URL(fileURLWithPath: puppet.app).appendingPathComponent("Contents/Resources/WrappLock.json")
        guard let data = try? Data(contentsOf: lock), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let bundle = json["bundle"] as? [String: Any] else { return nil }
        return bundle["id"] as? String
    }

    /// The module the bundle's test scenario is in (`tests.scenario`,
    /// `<module>/<scenario>`), whose needles it also uses.
    static func scenarioModule(_ bundleFolder: URL, modules: URL) -> String? {
        guard let test = try? ProgramTest.load(bundleFolder: bundleFolder, modulesRoot: modules) else { return nil }
        return test.scenario.id.split(separator: "/").first.map(String.init)
    }

    private static func relative(_ url: URL, to repo: URL) -> String {
        url.path.hasPrefix(repo.path + "/") ? String(url.path.dropFirst(repo.path.count + 1)) : url.path
    }
}

extension PuppetSession {
    /// Needles cut from this session's screens (`sc puppet name`).
    var needlesFolder: URL { folder.appendingPathComponent("needles") }
    /// The next numbered shot's path, as `shot` numbers them.
    func nextShot(suffix: String) -> URL {
        let number = ((try? FileManager.default.contentsOfDirectory(atPath: shots.path))?
            .filter { $0.hasSuffix(".png") && !$0.hasPrefix(".") }.count ?? 0) + 1
        return shots.appendingPathComponent(String(format: "%@-%03d-%@.png", name, number, suffix))
    }
}

/// A needle cut from a frame: its YAML, in the bundles' style, and its
/// picture for an image needle.
struct NeedleCut {
    let kind: String
    let yaml: String
    let image: CGImage?
    let summary: String
    /// Something to tell whoever cut it before they rely on it.
    var warning: String?

    /// The width a screen needle's picture is saved at, as WrappPuppeteer's
    /// `--make-splash-reference` saves one.
    static let screenWidth = 160

    static func make(tag: String, from frame: PuppetFrame, region: CGRect?, text: Bool, origin: String) throws -> NeedleCut {
        let header = "# \(tag): cut from \(origin) by sc puppet name. Say what it shows.\n"
        if text {
            var lines = frame.lines
            if let region { lines = lines.filter { region.contains(CGPoint(x: $0.box.midX, y: $0.box.midY)) } }
            let strings = lines.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !strings.isEmpty else { throw SCError("No text read \(region == nil ? "on the screen" : "in that region").") }
            let chosen = Array(strings.prefix(3))
            let yaml = header + """
                kind: "text"
                tags: ["\(tag)"]
                text: { strings: [\(chosen.map(quoted).joined(separator: ", "))] }

                """
            return NeedleCut(kind: "text", yaml: yaml, image: nil, summary: chosen.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        if let region {
            let pixels = frame.pixels(region)
            guard pixels.width >= 4, pixels.height >= 4, let image = frame.image.cropping(to: pixels) else {
                throw SCError("\(PuppetFrame.describe(region)) isn't inside the \(Int(frame.width))x\(Int(frame.height)) window.")
            }
            // Searched for around where it is now, sized to the window as it
            // is: its own size again on each side, but no more than a tenth
            // of the window, as a big region's would be most of the screen,
            // which costs several times as much to search (Icy Tower's logo).
            let marginX = min(region.width, frame.width * searchMargin)
            let marginY = min(region.height, frame.height * searchMargin)
            let search = region.insetBy(dx: -marginX, dy: -marginY)
                .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            let yaml = header + """
                kind: "region"
                tags: ["\(tag)"]
                region:
                  search: { x: \(fraction(search.minX / frame.width)), y: \(fraction(search.minY / frame.height)), \
                width: \(fraction(search.width / frame.width)), height: \(fraction(search.height / frame.height)) }
                  height-fraction: \(fraction(region.height / frame.height))

                """
            var cut = NeedleCut(kind: "region", yaml: yaml, image: image, summary: "\(image.width)x\(image.height) pixels of \(PuppetFrame.describe(region))")
            // A template search finds a flat patch anywhere there's one like
            // it, and its correlation is unsteady there, so it can't tell
            // this screen from another.
            if let spread = brightnessSpread(of: image), spread < flatSpread {
                cut.warning = "\(PuppetFrame.describe(region)) is nearly one colour all over (brightness varies by \(Int(spread.rounded())) of 255), "
                    + "so it would match any patch like it. Pick a part with an edge, a shape or text in it."
            }
            return cut
        }
        guard let content = ImageFingerprint.content(of: frame.image, width: screenWidth) else {
            throw SCError("The screen is blank (dark all over): nothing to know it by.")
        }
        let yaml = header + """
            kind: "screen"
            tags: ["\(tag)"]

            """
        return NeedleCut(kind: "screen", yaml: yaml, image: content, summary: "the picture, bars trimmed, \(content.width)x\(content.height)")
    }

    /// The most a region needle's search reaches past it on each side, as a
    /// fraction of the window.
    static let searchMargin = 0.1

    /// Below this spread of brightness (a standard deviation, 0–255) a
    /// region is flat: a dark sky, a plain panel.
    static let flatSpread = 6.0

    /// How much an image's brightness varies: the standard deviation of its
    /// grey levels, 0–255, read from a copy at most 64 pixels across.
    static func brightnessSpread(of image: CGImage) -> Double? {
        let scale = min(1, 64 / Double(max(image.width, image.height)))
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        var grey = [UInt8](repeating: 0, count: width * height)
        let drawn = grey.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let mean = grey.reduce(0.0) { $0 + Double($1) } / Double(grey.count)
        let variance = grey.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(grey.count)
        return variance.squareRoot()
    }

    static func quoted(_ string: String) -> String {
        "\"" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func fraction(_ value: Double) -> String {
        let rounded = (value * 10_000).rounded() / 10_000
        return rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(rounded)
    }
}

// MARK: Frames

/// The game window captured for matching: at its own scale, as `text`
/// captures it, with OCR's lines read once when asked for.
final class PuppetFrame {
    let path: URL
    let image: CGImage
    /// The window's size in points.
    let width: Double
    let height: Double

    init(path: URL, image: CGImage, width: Double, height: Double) {
        self.path = path
        self.image = image
        self.width = width
        self.height = height
    }

    deinit { try? FileManager.default.removeItem(at: path) }

    /// Pixels a point in the picture.
    var scale: Double { Double(image.width) / max(width, 1) }

    static func capture(_ puppet: PuppetSession) throws -> PuppetFrame {
        let size = PuppetShotCommand.windowSize(puppet)
        let path = puppet.shots.appendingPathComponent(".frame-\(UUID().uuidString).png")
        // Never above the window's own scale: asked for more, an OpenGL
        // game's surface comes back at its own size in a corner.
        _ = try puppet.ask(.capture(path: path.path, scale: size.scale), timeout: 20)
        guard let image = Frames.image(at: path) else {
            try? FileManager.default.removeItem(at: path)
            throw SCError("Couldn't read the capture of \(puppet.name)'s window.")
        }
        return PuppetFrame(path: path, image: image, width: size.width, height: size.height)
    }

    /// OCR's lines, boxes in window points.
    lazy var lines: [(text: String, box: CGRect)] = {
        // Enlarged pixel for pixel to at least 2 pixels a point: Vision
        // misreads small pixel fonts.
        let factor = Int((2 / scale).rounded(.up))
        let read = Frames.enlarged(image, by: factor) ?? image
        let perPoint = Double(read.width) / max(width, 1)
        return ((try? Frames.text(in: read)) ?? []).map { line in
            (line.text, CGRect(x: line.box.minX / perPoint, y: line.box.minY / perPoint,
                               width: line.box.width / perPoint, height: line.box.height / perPoint))
        }
    }()

    /// A rect in the picture's pixels, in window points.
    func points(_ pixels: CGRect) -> CGRect {
        CGRect(x: pixels.minX / scale, y: pixels.minY / scale, width: pixels.width / scale, height: pixels.height / scale)
    }

    /// A rect in fractions of the picture, in window points.
    func points(fraction: CGRect) -> CGRect {
        CGRect(x: fraction.minX * width, y: fraction.minY * height, width: fraction.width * width, height: fraction.height * height)
    }

    /// A rect in window points, in the picture's pixels, kept inside it.
    func pixels(_ points: CGRect) -> CGRect {
        CGRect(x: points.minX * scale, y: points.minY * scale, width: points.width * scale, height: points.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    }

    static func rect(_ text: String) -> CGRect? {
        let numbers = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 4, numbers[2] > 0, numbers[3] > 0 else { return nil }
        return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    /// "x,y wxh", in whole points.
    static func describe(_ rect: CGRect) -> String {
        "\(Int(rect.minX.rounded())),\(Int(rect.minY.rounded())) \(Int(rect.width.rounded()))x\(Int(rect.height.rounded()))"
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw SCError("Couldn't write \(url.path).")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw SCError("Couldn't write \(url.path).") }
    }
}
