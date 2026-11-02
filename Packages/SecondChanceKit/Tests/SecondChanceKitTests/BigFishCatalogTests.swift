import GameCatalog
import Testing

@Suite("Big Fish catalog")
struct BigFishCatalogTests {
    @Test(arguments: [
        ("F2435T1L1", 2435, 1, 1),
        ("F14014T1L1", 14014, 1, 1),
        ("f2435t1l4", 2435, 1, 4),
        ("F2234T1L2", 2234, 1, 2),
    ])
    func readsASKU(text: String, product: Int, platform: Int, language: Int) throws {
        let sku = try #require(BigFishSKU(text))
        #expect(sku.product == product)
        #expect(sku.platform == platform)
        #expect(sku.language == language)
        #expect(sku.description == text.uppercased())
    }

    @Test(arguments: ["", "F2435", "F2435T1", "2435T1L1", "F2435T1L", "FxT1L1", "F2435T1L1X", "F2435L1T1", "F-1T1L1"])
    func refusesWhatIsNotASKU(text: String) {
        #expect(BigFishSKU(text) == nil)
    }

    @Test func findsTheGameForAnyLanguagesSKU() throws {
        let provider = GameInfoProvider.shared
        #expect(provider.game(forBigFish: try #require(BigFishSKU("F2435T1L1")))?.id == "white-wolf")
        #expect(provider.game(forBigFish: try #require(BigFishSKU("F2435T1L4")))?.id == "white-wolf")
        #expect(provider.game(forBigFish: try #require(BigFishSKU("F7041T1L1")))?.id == "shadow-ranch")
        #expect(provider.game(forBigFish: BigFishSKU(product: 99_999)) == nil)
    }

    /// Big Fish sold 30 of them when the source was added (the store search in
    /// docs/big-fish.md lists them); not the two ScummVM-only originals or
    /// Ransom of the Seven Ships.
    @Test func knowsEveryGameBigFishSells() {
        let games = GameInfoProvider.shared.allGames()
        #expect(games.filter(\.isOnBigFish).count == 30)
        for slug in ["secrets-can-kill", "stay-tuned", "seven-ships"] {
            #expect(!GameInfoProvider.shared.gameInfo(for: slug).isOnBigFish, "\(slug)")
        }
    }

    @Test func productNumbersAreUnique() {
        let products = GameInfoProvider.shared.allGames().compactMap(\.bigFishProduct)
        #expect(Set(products).count == products.count)
    }
}
