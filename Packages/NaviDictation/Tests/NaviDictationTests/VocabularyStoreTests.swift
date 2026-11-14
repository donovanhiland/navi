import Foundation
import Testing
@testable import NaviDictation

@MainActor
@Suite("VocabularyStore")
struct VocabularyStoreTests {
    let folder = FileManager.default.temporaryDirectory.appending(path: "navi-vocab-\(UUID().uuidString)")
    var url: URL { folder.appending(path: "vocabulary.json") }
    let noEngine: VocabularyStore.Apply = { _ in }

    @Test("words survive a restart")
    func persists() {
        let store = VocabularyStore(url: url, apply: noEngine)
        store.add("Navi", soundsLike: ["navy"])
        store.learn(from: ["ask Donovan now", "and Donovan again"], isKnownWord: { _ in false })
        let reopened = VocabularyStore(url: url, apply: noEngine)
        #expect(reopened.vocabulary == store.vocabulary)
        #expect(reopened.added.map(\.text) == ["Navi"])
        #expect(reopened.learned.map(\.text) == ["Donovan"])
    }

    @Test("an unreadable file is kept aside and the list starts empty")
    func unreadable() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let store = VocabularyStore(url: url, apply: noEngine)
        #expect(store.vocabulary == .empty)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "vocabulary.unreadable.json").path))
    }

    @Test("adding a word that is already there changes nothing")
    func duplicate() {
        let store = VocabularyStore(url: url, apply: noEngine)
        #expect(store.add("Navi"))
        #expect(!store.add("Navi"))
    }
}

@MainActor
@Suite("SystemDictionary")
struct SystemDictionaryTests {
    @Test("capitalized names are unknown and plain words are known")
    func names() {
        #expect(SystemDictionary.knows("hello"))
        #expect(SystemDictionary.knows("Hello"))
        #expect(!SystemDictionary.knows("Zxqvbnite"))
        #expect(!SystemDictionary.knows("FluidAudio"))
    }
}
