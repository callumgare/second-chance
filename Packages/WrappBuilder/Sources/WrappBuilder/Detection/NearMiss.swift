//
//  NearMiss.swift
//  WrappBuilder
//
//  A disc or download nothing recognised that something nearly did, so an
//  edition not known yet shows up in the failure reports, as ScummVM asks
//  for unknown variants to be sent in.

import Foundation

/// Something that nearly matched a source nothing recognised. What a basic
/// report may carry is fixed: the bundle, the way it nearly matched, the
/// kinds of name the source had, and for a hash, the file's name on the
/// disc, its size and its md5 (as ScummVM sends its own team). Never the
/// names themselves, which hold whatever an installer put there.
public nonisolated struct NearMiss: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable {
        /// Most of a title's words are in the fingerprint, not the title.
        case titleWords = "title-words"
        /// The fingerprint names a series ("Nancy Drew") and no program in it.
        case series
        /// A file a hash matcher names is there, with another size or md5.
        case fileHash = "file-hash"
    }

    /// A file a hash matcher looked at, as it is on this disc.
    public struct HashedFile: Hashable, Sendable {
        /// Its path from the top of the disc.
        public let name: String
        public let size: Int
        /// The md5 of as many bytes as the matcher hashes.
        public let md5: String
    }

    /// The bundle that nearly matched; nil when only its series did.
    public let bundleID: String?
    public let reason: Reason
    /// The series named, for `series`.
    public let series: String?
    public let signalKinds: [DetectionSource.SignalKind]
    public let file: HashedFile?
}

nonisolated extension DetectionIndex {
    /// Words too common in titles to say anything.
    static let titleStopWords: Set<String> = ["the", "of", "a", "an", "in", "on", "at", "to", "for", "by", "and"]

    /// A title's or fingerprint's words, lower-cased.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// What nearly matched a source nothing did: a hash matcher's file
    /// there with another size or md5, then the title most of whose words
    /// the fingerprint has (more than half; the most, then the first id),
    /// then a series it names.
    func nearMiss(_ source: DetectionSource, files: SourceFiles) -> NearMiss? {
        let kinds = source.signalKinds
        for rule in others {
            guard case .fileHash(let glob, _, _, let bytes) = rule.matcher,
                  let file = files.matching(glob).first,
                  let size = SourceFiles.size(of: file.url),
                  let md5 = files.md5(of: file.url, bytes: bytes) else { continue }
            return NearMiss(bundleID: rule.bundleID, reason: .fileHash, series: nil, signalKinds: kinds,
                            file: .init(name: file.path, size: size, md5: md5))
        }

        let fingerprintWords = Set(Self.words(source.fingerprint))
        var bestShare = 0.0
        var nearest: Program?
        for program in programs.sorted(by: { $0.bundleID < $1.bundleID }) {
            let titleWords = Set(Self.words(program.title)).subtracting(Self.titleStopWords)
            guard !titleWords.isEmpty else { continue }
            let found = titleWords.intersection(fingerprintWords).count
            let share = Double(found) / Double(titleWords.count)
            if found * 2 > titleWords.count, share > bestShare {
                bestShare = share
                nearest = program
            }
        }
        if let nearest {
            return NearMiss(bundleID: nearest.bundleID, reason: .titleWords, series: nil, signalKinds: kinds, file: nil)
        }

        let lowercased = source.fingerprint.lowercased()
        let named = Set(programs.compactMap(\.series)).sorted().first { lowercased.contains($0.lowercased()) }
        return named.map { NearMiss(bundleID: nil, reason: .series, series: $0, signalKinds: kinds, file: nil) }
    }
}
