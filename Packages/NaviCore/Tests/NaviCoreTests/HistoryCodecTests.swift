import Foundation
import Testing
@testable import NaviCore

struct HistoryCodecTests {
    private func item(_ n: Int, text: String? = "plain \\ text") -> CaptureItem {
        CaptureItem(
            id: UUID(), kind: CaptureKind.allCases[n % CaptureKind.allCases.count],
            createdAt: Date(timeIntervalSince1970: 1_767_225_600 + Double(n) * 0.37),
            lastUsedAt: Date(timeIntervalSince1970: 1_767_225_700 + Double(n)), copyCount: n + 1, pinned: n % 2 == 0,
            text: text, fileName: n % 3 == 0 ? "f\(n).png" : nil,
            sourceApp: n % 4 == 0 ? nil : "App \(n)", sourceBundleID: n % 5 == 0 ? nil : "com.example.\(n)",
            contentHash: String(repeating: "ab", count: 32)
        )
    }

    @Test func readsWhatJSONEncoderWrites() throws {
        let items = (0..<30).map { item($0) }
        let data = try JSONEncoder().encode(items)
        #expect(HistoryCodec.decode(data) == items)
    }

    @Test func readsEscapesAndSurrogatePairs() throws {
        let text = "quote \" slash \\ solidus / tab \t newline \n cr \r bell \u{07} nul-ish \u{01} emoji \u{1F600} é 日本 \u{2028}"
        let items = [item(1, text: text), item(2, text: ""), item(3, text: nil)]
        let data = try JSONEncoder().encode(items)
        #expect(HistoryCodec.decode(data) == items)
        let escaped = """
        [{"id":"\(UUID().uuidString)","kind":"text","createdAt":5,"pinned":false,"contentHash":"h",\
        "text":"a\\u00e9\\ud83d\\ude00\\n\\/\\b\\f"}]
        """
        let decoded = try #require(HistoryCodec.decode(Data(escaped.utf8)))
        #expect(decoded[0].text == "aé\u{1F600}\n/\u{08}\u{0C}")
    }

    @Test func readsPrettyPrintedFilesNullsAndUnknownKeys() throws {
        let items = (0..<6).map { item($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        #expect(HistoryCodec.decode(try encoder.encode(items)) == items)
        let json = """
        [ {"future": {"a": [1, 2, {"b": "}"}], "c": null}, "id": "\(UUID().uuidString.lowercased())", "kind": "image",
           "createdAt": 1.5e2, "lastUsedAt": null_is_not_json, "pinned": true, "contentHash": "h", "text": null} ]
        """
        #expect(HistoryCodec.decode(Data(json.utf8)) == nil)
        let valid = """
        [ {"future": {"a": [1, 2, {"b": "}"}], "c": null}, "id": "\(UUID().uuidString.lowercased())", "kind": "image",
           "createdAt": 1.5e2, "pinned": true, "contentHash": "h", "text": null, "sourceApp": "S"} ]
        """
        let decoded = try #require(HistoryCodec.decode(Data(valid.utf8)))
        #expect(decoded.count == 1 && decoded[0].kind == .image && decoded[0].text == nil && decoded[0].sourceApp == "S")
        #expect(decoded[0].createdAt == Date(timeIntervalSinceReferenceDate: 150))
        #expect(decoded[0].lastUsedAt == decoded[0].createdAt && decoded[0].copyCount == 1)
    }

    @Test func rejectsWhatItCannotReadSoTheOldDecoderTakesOver() {
        #expect(HistoryCodec.decode(Data("[{\"id\":".utf8)) == nil)
        #expect(HistoryCodec.decode(Data("{}".utf8)) == nil)
        #expect(HistoryCodec.decode(Data("[]".utf8)) == [])
        let badKind = "[{\"id\":\"\(UUID().uuidString)\",\"kind\":\"nope\",\"createdAt\":1,\"pinned\":false,\"contentHash\":\"h\"}]"
        #expect(HistoryCodec.decode(Data(badKind.utf8)) == nil)
        #expect(throws: (any Error).self) { try CaptureItem.decodeHistory(from: Data(badKind.utf8)) }
    }

    @Test func bigFilesDecodeInPartsToTheSameItems() throws {
        let filler = String(repeating: "the report \"quoted\" },{\"id\":1 \n", count: 200)
        let items = (0..<400).map { item($0, text: filler + "\($0)") }
        let data = try JSONEncoder().encode(items)
        #expect(data.count > 2 * 1024 * 1024)
        #expect(HistoryCodec.decode(data) == items)
    }

    @Test func encoderOutputReadsBackThroughBothDecoders() throws {
        let tricky = "q\" b\\ s/ \t\n\r \u{01} \u{1F} \u{7F} é \u{1F600} \u{2028} " + String(repeating: "long ", count: 40)
        let items = (0..<40).map { item($0, text: $0 % 7 == 0 ? tricky : "item \($0)") } + [item(99, text: nil)]
        var cache = EncodedItems()
        let data = cache.encode(items)
        #expect(try JSONDecoder().decode([CaptureItem].self, from: data) == items)
        #expect(HistoryCodec.decode(data) == items)
        #expect(cache.encode(items) == data)
        var changed = items
        changed[3].copyCount += 1
        changed.remove(at: 5)
        let second = cache.encode(changed)
        #expect(try JSONDecoder().decode([CaptureItem].self, from: second) == changed)
        var fresh = EncodedItems()
        #expect(fresh.encode(changed) == second)
        #expect(fresh.encode([]) == Data("[]".utf8))
    }
}
