import Foundation
import Logging

private nonisolated let logger = Logger(label: "au.gare.callum.second-chance.SecondChance.IconLab.CLIPTokenizer")

/// CLIP's byte-level BPE tokenizer (OpenAI's `simple_tokenizer.py`, which MobileCLIP's text encoder uses), from
/// the `vocab.json` and `merges.txt` HF publishes with `openai/clip-vit-base-patch32`.
///
/// Text is lower-cased with runs of whitespace collapsed (CLIP also runs ftfy and an HTML unescape, which only
/// matter for mangled or escaped text, not our prompts); split by CLIP's pattern; each piece's UTF-8 bytes mapped
/// to printable characters (GPT-2's `bytes_to_unicode`); and merged pair by pair, lowest merge rank first, the
/// last character carrying `</w>`. Tokens are wrapped in `<|startoftext|>` … `<|endoftext|>` and padded with 0 to
/// 77, as open_clip's `tokenize` does (the encoder finds the end by the largest id).
nonisolated public final class CLIPTokenizer: Sendable {
    public static let contextLength = 77
    public let startToken: Int32
    public let endToken: Int32
    private let encoder: [String: Int32]
    private let ranks: [Pair: Int]
    private static let byteEncoder: [UInt8: Character] = makeByteEncoder()
    private static let pattern: NSRegularExpression? = {
        do {
            return try NSRegularExpression(
                pattern: #"<\|startoftext\|>|<\|endoftext\|>|'s|'t|'re|'ve|'m|'ll|'d|[\p{L}]+|[\p{N}]|[^\s\p{L}\p{N}]+"#,
                options: [.caseInsensitive])
        } catch {
            logger.error("CLIP's token pattern doesn't compile: \(error)")
            return nil
        }
    }()

    struct Pair: Hashable { let a: String; let b: String }

    public init(folder: URL) throws {
        let vocab = try JSONDecoder().decode([String: Int32].self, from: Data(contentsOf: folder.appendingPathComponent("vocab.json")))
        let merges = try String(contentsOf: folder.appendingPathComponent("merges.txt"), encoding: .utf8)
        var r: [Pair: Int] = [:]
        var rank = 0
        for line in merges.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("#version") { continue }
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            r[Pair(a: String(parts[0]), b: String(parts[1]))] = rank
            rank += 1
        }
        guard let s = vocab["<|startoftext|>"], let e = vocab["<|endoftext|>"] else {
            throw IconLabError.invalid("CLIP vocabulary without its start and end tokens")
        }
        encoder = vocab
        ranks = r
        startToken = s
        endToken = e
    }

    static func makeByteEncoder() -> [UInt8: Character] {
        var bs = Array(Int(UInt8(ascii: "!"))...Int(UInt8(ascii: "~"))) + Array(0xA1...0xAC) + Array(0xAE...0xFF)
        var cs = bs
        var n = 0
        for b in 0..<256 where !bs.contains(b) {
            bs.append(b)
            cs.append(256 + n)
            n += 1
        }
        var out: [UInt8: Character] = [:]
        for (b, c) in zip(bs, cs) { if let scalar = UnicodeScalar(UInt32(c)) { out[UInt8(b)] = Character(scalar) } }   // all in the BMP
        return out
    }

    /// The text's token ids, without the start and end tokens.
    public func encode(_ text: String) -> [Int32] {
        let clean = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        let ns = clean as NSString
        var ids: [Int32] = []
        guard let pattern = Self.pattern else { return ids }
        for m in pattern.matches(in: clean, range: NSRange(location: 0, length: ns.length)) {
            let piece = ns.substring(with: m.range)
            let mapped = String(piece.utf8.compactMap { Self.byteEncoder[$0] })   // every byte has one
            for t in bpe(mapped) { if let id = encoder[t] { ids.append(id) } }
        }
        return ids
    }

    /// Start, the text's tokens (cut to fit), end, then zeros to 77.
    public func tokenize(_ text: String) -> [Int32] {
        var ids = [startToken] + encode(text).prefix(Self.contextLength - 2) + [endToken]
        ids += [Int32](repeating: 0, count: Self.contextLength - ids.count)
        return ids
    }

    func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        while word.count > 1 {
            var best: (rank: Int, i: Int)?
            for i in 0..<(word.count - 1) {
                if let r = ranks[Pair(a: word[i], b: word[i + 1])], r < (best?.rank ?? .max) { best = (r, i) }
            }
            guard let b = best else { break }
            let first = word[b.i], second = word[b.i + 1]
            var merged: [String] = []
            var i = 0
            while i < word.count {
                if i < word.count - 1, word[i] == first, word[i + 1] == second {
                    merged.append(first + second)
                    i += 2
                } else {
                    merged.append(word[i])
                    i += 1
                }
            }
            word = merged
        }
        return word
    }
}
