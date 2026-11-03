//
//  BigFishSKU.swift
//  GameCatalog
//
//  A game's identity on Big Fish Games.

import Foundation

/// A Big Fish Games SKU (Big Fish also calls it a wrapping ID): `F2435T1L1`
/// is product 2435 (The White Wolf of Icicle Creek) for Windows (`T1`) in
/// English (`L1`). The Game Manager downloads, installs and names a game's
/// folders by it.
public nonisolated struct BigFishSKU: Hashable, Codable, Sendable, CustomStringConvertible {
    public let product: Int
    public let platform: Int
    public let language: Int

    /// Windows: the only platform a Nancy Drew game comes on there that runs here.
    public static let windows = 1
    /// The English edition's language number.
    public static let english = 1

    public init(product: Int, platform: Int = windows, language: Int = english) {
        self.product = product
        self.platform = platform
        self.language = language
    }

    /// Reads `F<product>T<platform>L<language>`, as Big Fish writes it (any case).
    public init?(_ text: String) {
        let scanner = text.uppercased().unicodeScalars
        var parts: [Int] = []
        var expected: [Character] = ["F", "T", "L"]
        var number: String?
        for scalar in scanner {
            let character = Character(scalar)
            if let first = expected.first, character == first {
                if let digits = number {
                    guard let value = Int(digits) else { return nil }
                    parts.append(value)
                }
                number = ""
                expected.removeFirst()
            } else if character.isASCII, character.isNumber, number != nil {
                number? += String(character)
            } else {
                return nil
            }
        }
        guard expected.isEmpty, let digits = number, let last = Int(digits), parts.count == 2 else { return nil }
        self.init(product: parts[0], platform: parts[1], language: last)
    }

    public var description: String { "F\(product)T\(platform)L\(language)" }
}
