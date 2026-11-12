import Foundation
import Testing
@testable import NaviCore

@MainActor
struct InboxSearchTests {
    let directory = FileManager.default.temporaryDirectory.appending(path: "NaviTests-\(UUID().uuidString)")
    let start = Date(timeIntervalSince1970: 1_000_000)

    private func texts(_ inbox: Inbox, _ query: String) -> [String?] {
        inbox.search(query).map(\.text)
    }

    @Test func ignoresCase() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "Hello World", now: start)
        #expect(texts(inbox, "hello") == ["Hello World"])
        #expect(texts(inbox, "WORLD") == ["Hello World"])
    }

    @Test func ignoresAccentsBothWays() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "café au lait", now: start)
        inbox.add(text: "cafe noir", now: start + 1)
        inbox.add(text: "Reunião às 10", now: start + 2)
        #expect(texts(inbox, "cafe") == ["cafe noir", "café au lait"])
        #expect(texts(inbox, "café") == ["cafe noir", "café au lait"])
        #expect(texts(inbox, "CAFÉ AU") == ["café au lait"])
        #expect(texts(inbox, "acao").isEmpty)
        #expect(texts(inbox, "reuniao as") == ["Reunião às 10"])
        #expect(texts(inbox, "reunião") == ["Reunião às 10"])
    }

    @Test func findsAccentedTextInBothNormalizationForms() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "informação".precomposedStringWithCanonicalMapping, now: start)
        inbox.add(text: "ação".decomposedStringWithCanonicalMapping, now: start + 1)
        #expect(inbox.search("acao").count == 2)
        #expect(inbox.search("ação".decomposedStringWithCanonicalMapping).count == 2)
        #expect(inbox.search("informacao").count == 1)
        #expect(inbox.search("INFORMAÇÃO").count == 1)
    }

    @Test func ignoresCharacterWidthAndFoldsSharpS() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "Straße", now: start)
        inbox.add(text: "ＡＢＣ", now: start + 1)
        #expect(texts(inbox, "strasse") == ["Straße"])
        #expect(texts(inbox, "abc") == ["ＡＢＣ"])
    }

    @Test func searchesTextWithEmojiAndOtherScripts() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "ótimo 👍🏽 trabalho €10 nº 5", now: start)
        inbox.add(text: "日本語のテキスト", now: start + 1)
        inbox.add(text: "Привет мир", now: start + 2)
        #expect(texts(inbox, "otimo").count == 1)
        #expect(texts(inbox, "€10").count == 1)
        #expect(texts(inbox, "nº 5").count == 1)
        #expect(texts(inbox, "テキスト").count == 1)
        #expect(texts(inbox, "ПРИВЕТ").count == 1)
        #expect(texts(inbox, "9999").isEmpty)
    }

    @Test func digitQueriesMatchLiterally() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "versão v2 do arquivo 9999", now: start)
        #expect(inbox.search("v2").count == 1)
        #expect(inbox.search("9999").count == 1)
        #expect(inbox.search("v3").isEmpty)
    }

    @Test func findsEverythingTheSystemSearchFindsInAccentedText() {
        let words = [
            "ação", "informação", "Reunião", "não", "São Paulo", "configuração", "título", "área", "você", "também",
            "opção", "câmera", "médico", "coração", "relatorio", "reuniao", "acao", "de", "para", "projeto 2024", "v2",
            "nº 5", "€10", "R$ 9,99", "https://exemplo.com.br/a?b=1", "👍", "e-mail",
        ]
        var generator = SeededGenerator(seed: 5)
        let inbox = Inbox(directory: directory, limit: 1000)
        for index in 0..<300 {
            var text = (0..<Int.random(in: 1...8, using: &generator)).map { _ in words.randomElement(using: &generator)! }
                .joined(separator: " ") + " #\(index)"
            if index % 3 == 1 { text = text.decomposedStringWithCanonicalMapping }
            inbox.add(text: text, sourceApp: index % 5 == 0 ? "Câmera" : "Notes", now: start + Double(index))
        }
        let queries = words + ["a", "e", "ã", "ao", "ção", "REUNIÃO", "ca", "2024", "projeto 20", "o p", "tulo", "ç", "9,99", "v2", "1"]
        for query in queries + queries.map(\.decomposedStringWithCanonicalMapping) {
            let found = Set(inbox.search(query).map(\.id))
            let old = inbox.items.filter {
                ($0.text?.localizedCaseInsensitiveContains(query) ?? false)
                    || ($0.sourceApp?.localizedCaseInsensitiveContains(query) ?? false)
            }
            #expect(old.allSatisfy { found.contains($0.id) }, "query \(query.debugDescription)")
        }
    }

    @Test func matchesSourceApp() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "one", sourceApp: "Safari", now: start)
        inbox.add(text: "two", sourceApp: "Câmera", now: start + 1)
        #expect(texts(inbox, "safari") == ["one"])
        #expect(texts(inbox, "camera") == ["two"])
    }

    @Test func noMatchReturnsNothing() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "one", sourceApp: "Safari", now: start)
        #expect(inbox.search("zzz").isEmpty)
    }

    @Test func emptyQueryReturnsEverything() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "one", now: start)
        inbox.add(text: "two", now: start + 1)
        #expect(texts(inbox, "  ") == ["two", "one"])
    }

    @Test func keepsDisplayOrder() {
        let inbox = Inbox(directory: directory)
        let a = inbox.add(text: "match a", now: start)
        inbox.add(text: "match b", now: start + 1)
        inbox.add(text: "match c", now: start + 2)
        #expect(texts(inbox, "match") == ["match c", "match b", "match a"])
        inbox.togglePin(a!.id)
        #expect(texts(inbox, "match") == ["match a", "match c", "match b"])
    }

    @Test func seesNewItems() {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "alpha", now: start)
        #expect(texts(inbox, "beta").isEmpty)
        inbox.add(text: "beta", now: start + 1)
        #expect(texts(inbox, "beta") == ["beta"])
    }

    @Test func dropsRemovedItems() throws {
        let inbox = Inbox(directory: directory)
        let item = try #require(inbox.add(text: "alpha", now: start))
        inbox.add(text: "alpha two", now: start + 1)
        #expect(inbox.search("alpha").count == 2)
        inbox.remove(item.id)
        #expect(texts(inbox, "alpha") == ["alpha two"])
    }

    @Test func clearUnpinnedDropsMatches() throws {
        let inbox = Inbox(directory: directory)
        let kept = try #require(inbox.add(text: "alpha kept", now: start))
        inbox.add(text: "alpha gone", now: start + 1)
        inbox.togglePin(kept.id)
        #expect(inbox.search("alpha").count == 2)
        inbox.clearUnpinned()
        #expect(texts(inbox, "alpha") == ["alpha kept"])
        inbox.remove(kept.id)
        #expect(inbox.search("alpha").isEmpty)
    }

    @Test func editingFileKeepsItemSearchable() throws {
        let inbox = Inbox(directory: directory)
        let shot = try #require(inbox.add(
            fileData: Data([1]), fileExtension: "png", kind: .screenshot, sourceApp: "Preview", now: start
        ))
        #expect(inbox.updateFile(shot.id, data: Data([2])))
        #expect(inbox.search("preview").map(\.id) == [shot.id])
    }

    @Test func searchesBeforeAndAfterTheBackgroundKeysAreBuilt() async throws {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "Reunião de projeto", now: start)
        inbox.add(text: "plain text", now: start + 1)
        inbox.flush()
        let reloaded = Inbox(directory: directory)
        let before = reloaded.search("reuniao").map(\.id)
        while !reloaded.isSearchReady { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reloaded.search("reuniao").map(\.id) == before)
        #expect(before.count == 1)
    }

    @Test func coldSearchWithNoBudgetIsPartialThenCompleteAfterWarmUp() async throws {
        let inbox = Inbox(directory: directory)
        for index in 0..<40 {
            inbox.add(text: "Reunião número \(index)", now: start + Double(index))
        }
        let expected = inbox.search("reuniao").map(\.id)
        #expect(expected.count == 40)

        inbox.flush()
        let reloaded = Inbox(directory: directory)
        reloaded.searchBudget = .zero
        let versionBefore = reloaded.searchKeysVersion
        #expect(reloaded.search("reuniao").isEmpty)
        #expect(reloaded.deferredSearchItems == 40)
        while !reloaded.isSearchReady { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reloaded.searchKeysVersion > versionBefore)
        #expect(reloaded.search("reuniao").map(\.id) == expected)
        #expect(reloaded.deferredSearchItems == 0)
    }

    @Test func largeAddedTextBecomesSearchableAfterTheBackgroundKeyLands() async throws {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "pequeno", now: start)
        let big = String(repeating: "Привет мир 日本語 😀 ", count: 4000) + "агентство"
        #expect(big.utf8.count > Inbox.inlineKeyLimit)
        inbox.add(text: big, now: start + 1)
        inbox.searchBudget = .zero
        #expect(inbox.search("агентство").isEmpty)
        #expect(inbox.deferredSearchItems == 1)
        while !inbox.isSearchReady { try await Task.sleep(for: .milliseconds(5)) }
        #expect(inbox.search("АГЕНТСТВО").count == 1)
        #expect(inbox.deferredSearchItems == 0)
    }

    @Test func partialColdSearchKeepsTheItemsItHasKeysFor() throws {
        let inbox = Inbox(directory: directory)
        inbox.add(text: "um dois", now: start)
        inbox.add(text: "um três", now: start + 1)
        inbox.flush()
        let reloaded = Inbox(directory: directory)
        reloaded.searchBudget = .seconds(10)
        #expect(reloaded.search("um").count == 2)
        reloaded.searchBudget = .zero
        #expect(reloaded.search("um").count == 2)
        #expect(reloaded.deferredSearchItems == 0)
    }

    @Test func coldSearchDoesNotFoldAHugeItem() async throws {
        let inbox = Inbox(directory: directory)
        let huge = String(repeating: "Привет мир 日本語のテキスト 😀 ", count: 40_000) + " агентство"
        #expect(huge.utf8.count >= 2_000_000)
        inbox.add(text: "pequeno", now: start)
        inbox.add(text: huge, now: start + 1)
        inbox.flush()
        let reloaded = Inbox(directory: directory)
        reloaded.searchBudget = .seconds(10)
        var found: [CaptureItem] = []
        let elapsed = ContinuousClock().measure { found = reloaded.search("агентство") }
        #expect(found.isEmpty)
        #expect(reloaded.deferredSearchItems == 1)
        #expect(!reloaded.isSearchReady)
        #expect(elapsed < .milliseconds(30))
        while !reloaded.isSearchReady { try await Task.sleep(for: .milliseconds(5)) }
        #expect(reloaded.search("агентство").count == 1)
        #expect(reloaded.deferredSearchItems == 0)
    }

    @Test func removedAndEvictedItemsLoseTheirSearchKeys() {
        let inbox = Inbox(directory: directory, limit: 2)
        inbox.add(text: "alpha", now: start)
        inbox.add(text: "beta", now: start + 1)
        #expect(inbox.searchKeyCount == 2)
        inbox.add(text: "gamma", now: start + 2)
        #expect(inbox.items.map(\.text) == ["gamma", "beta"])
        #expect(inbox.searchKeyCount == 2)
        #expect(inbox.search("alpha").isEmpty)
        inbox.remove(inbox.items[0].id)
        #expect(inbox.searchKeyCount == 1)
        inbox.clearUnpinned()
        #expect(inbox.searchKeyCount == 0)
    }

}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
