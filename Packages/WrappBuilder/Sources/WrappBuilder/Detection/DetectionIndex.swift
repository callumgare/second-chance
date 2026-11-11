//
//  DetectionIndex.swift
//  WrappBuilder
//
//  Every bundle's matchers, compiled into one index, and what a disc or
//  download is by them. docs/program-bundles.md has the rules.

import Foundation

/// Every bundle's matchers in one index, made once when the bundles load,
/// so recognising a disc over hundreds of bundles stays quick.
///
/// Matchers have no order. Of the bundles that match, the one whose match is
/// most specific (`Specificity`: the longest text matched) is the program:
/// "Secrets Can Kill Remastered" wins over Secrets Can Kill, whose title it
/// contains, without a priority field. Two bundles tied for most specific
/// are `ambiguous`, never whichever comes first.
public nonisolated struct DetectionIndex: Sendable {
    /// One matcher, and whose it is.
    public struct Rule: Hashable, Sendable {
        public let bundleID: String
        /// The edition whose `detect.matchers` has it; nil for the default
        /// matcher (title, aliases, codes), which is the whole bundle's.
        public let edition: String?
        public let matcher: Matcher

        public init(bundleID: String, edition: String? = nil, matcher: Matcher) {
            self.bundleID = bundleID
            self.edition = edition
            self.matcher = matcher
        }
    }

    /// What a near miss is measured against: a bundle's title and series.
    public struct Program: Hashable, Sendable {
        public let bundleID: String
        public let title: String
        public let series: String?

        public init(bundleID: String, title: String, series: String? = nil) {
            self.bundleID = bundleID
            self.title = title
            self.series = series
        }
    }

    /// A rule that matched.
    public struct Match: Hashable, Sendable {
        public let rule: Rule
        public var bundleID: String { rule.bundleID }
        public var specificity: Specificity { rule.matcher.specificity }
    }

    /// A bundle's `installed` sign.
    public struct InstalledRule: Hashable, Sendable {
        public let bundleID: String
        public let sign: InstalledSign

        public init(bundleID: String, sign: InstalledSign) {
            self.bundleID = bundleID
            self.sign = sign
        }
    }

    public enum Result: Hashable, Sendable {
        /// One bundle's match is the most specific.
        case recognised(Match)
        /// Two or more bundles tie for most specific: the best match of each.
        case ambiguous([Match])
        /// Nothing matched; perhaps something nearly did.
        case unrecognised(NearMiss?)
    }

    // The index: text matchers longest first, words by their text, and the
    // matchers that look at files or the volume, which few bundles have.
    private let texts: [(text: String, rule: Rule)]
    private let words: [String: [Rule]]
    let others: [Rule]
    /// How deep the file matchers' globs go: how deep a source is listed.
    private let fileDepth: Int
    let programs: [Program]
    /// Every bundle's `installed` signs, kept apart from `rules`: a sign
    /// turns a folder down, and never says which program a source is.
    let installed: [InstalledRule]

    public init(rules: [Rule], programs: [Program], installed: [InstalledRule] = []) {
        texts = rules.compactMap { rule in
            if case .text(let text) = rule.matcher { (text.lowercased(), rule) } else { nil }
        }.sorted { $0.text.count > $1.text.count }
        words = Dictionary(grouping: rules.filter { if case .word = $0.matcher { true } else { false } }) { rule in
            if case .word(let word) = rule.matcher { word } else { "" }
        }
        others = rules.filter {
            switch $0.matcher {
            case .text, .word: false
            default: true
            }
        }
        fileDepth = (others.compactMap(\.matcher.file) + installed.flatMap(\.sign.matchers).compactMap(\.file))
            .map { $0.split(separator: "/").count }.max() ?? 0
        self.programs = programs
        self.installed = installed
    }

    /// The index of `bundles`' matchers.
    public init(bundles: [ProgramBundle]) {
        self.init(manifests: bundles.map(\.manifest))
    }

    /// The index of every bundle under `root`, their manifests checked
    /// against the schema but not their Wrappfiles, which detection
    /// doesn't read.
    public static func load(bundlesAt root: URL) throws -> DetectionIndex {
        let loader = try ProgramBundleLoader(root: root, modules: nil)
        return DetectionIndex(bundles: try loader.loadAll().get())
    }

    public init(manifests: [Manifest]) {
        self.init(rules: manifests.flatMap(Self.rules), programs: manifests.map {
            Program(bundleID: $0.id, title: $0.title, series: $0.series)
        }, installed: manifests.flatMap { manifest in
            manifest.installedSigns.map { InstalledRule(bundleID: manifest.id, sign: $0) }
        })
    }

    /// A manifest's matchers: the default one, from its title (without a
    /// leading "The", which discs leave off) and every edition's aliases and
    /// codes, whatever the source; then each edition's own.
    public static func rules(_ manifest: Manifest) -> [Rule] {
        let title = manifest.title.lowercased()
        let names = [title.hasPrefix("the ") ? String(title.dropFirst(4)) : title]
            + manifest.editions.flatMap { $0.detect?.aliases ?? [] }.map { $0.lowercased() }
        let codes = manifest.editions.flatMap { $0.detect?.codes ?? [] }
        var rules = unique(names).map { Rule(bundleID: manifest.id, matcher: .text($0)) }
            + unique(codes).map { Rule(bundleID: manifest.id, matcher: .word($0)) }
        for edition in manifest.editions {
            rules += (edition.detect?.matchers ?? []).map { Rule(bundleID: manifest.id, edition: edition.id, matcher: $0) }
        }
        return rules
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: - Detecting

    /// What `source` is. Reads the files the matchers that look at files
    /// name, so off the main thread for a disc.
    public func detect(_ source: DetectionSource, readers: WindowsReaders = .standard) -> Result {
        let files = SourceFiles(source.location, depth: fileDepth, readers: readers)
        let matches = self.matches(source, files: files)

        // Each bundle's most specific match, then the most specific of those.
        var best: [String: Match] = [:]
        for match in matches where best[match.bundleID].map({ $0.specificity < match.specificity }) ?? true {
            best[match.bundleID] = match
        }
        let ranked = best.values.sorted { ($0.specificity, $1.bundleID) > ($1.specificity, $0.bundleID) }
        guard let top = ranked.first else {
            return .unrecognised(nearMiss(source, files: files))
        }
        let tied = ranked.filter { $0.specificity == top.specificity }
        return tied.count > 1 ? .ambiguous(tied.sorted { $0.bundleID < $1.bundleID }) : .recognised(top)
    }

    /// The signs by which `source` holds a program already installed: the
    /// most specific of the bundles' `installed` signs that match, more than
    /// one only when they tie (ten Nancy Drew games' program is `Game.exe`),
    /// sorted by bundle; empty when none does. Reads the files the signs
    /// name, so off the main thread.
    public func installedCopy(_ source: DetectionSource, readers: WindowsReaders = .standard) -> [InstalledRule] {
        guard !installed.isEmpty else { return [] }
        let files = SourceFiles(source.location, depth: fileDepth, readers: readers)
        let matching = installed.filter { rule in rule.sign.matchers.allSatisfy { Self.matches($0, source: source, files: files) } }
        guard let best = matching.map(\.sign.specificity).max() else { return [] }
        return matching.filter { $0.sign.specificity == best }.sorted { $0.bundleID < $1.bundleID }
    }

    /// Every rule that matches `source`.
    func matches(_ source: DetectionSource, files: SourceFiles) -> [Match] {
        let fingerprint = source.fingerprint
        let lowercased = fingerprint.lowercased()
        var matches = texts.filter { lowercased.contains($0.text) }.map { Match(rule: $0.rule) }
        // A word is between spaces, or the fingerprint's ends.
        for word in Set(fingerprint.split(separator: " ").map(String.init)) {
            matches += (words[word] ?? []).map { Match(rule: $0) }
        }
        matches += others.filter { Self.matches($0.matcher, source: source, files: files) }.map { Match(rule: $0) }
        return matches
    }

    private static func matches(_ matcher: Matcher, source: DetectionSource, files: SourceFiles) -> Bool {
        switch matcher {
        case .text, .word:
            return false
        case .fileExists(let glob):
            return !files.matching(glob).isEmpty
        case .fileContains(let glob, let text):
            return files.matching(glob).contains { SourceFiles.file($0.url, contains: text) }
        case .fileHash(let glob, let size, let md5, let bytes):
            return files.matching(glob).contains { file in
                SourceFiles.size(of: file.url) == size && files.md5(of: file.url, bytes: bytes) == md5
            }
        case .exeVersion(let glob, let key, let text):
            return files.matching(glob).contains { file in
                files.versionString(key, of: file.url)?.lowercased().contains(text.lowercased()) == true
            }
        case .msiSummary(let glob, let subject):
            return files.matching(glob).contains { file in
                files.msiSubject(of: file.url)?.lowercased().contains(subject.lowercased()) == true
            }
        case .volumeName(let glob):
            return source.volumeName.map { SourceFiles.glob(glob, matches: $0) } ?? false
        }
    }
}
