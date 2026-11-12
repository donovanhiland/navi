import AppKit
import CryptoKit
import Foundation
import NaviCore

enum HistorySeeder {
    static let vocabulary = [
        "the", "and", "report", "invoice", "meeting", "budget", "design", "review", "notes", "draft",
        "client", "update", "project", "schedule", "travel", "lunch", "email", "contract", "screenshot", "release",
        "feature", "network", "server", "backup", "library", "record", "export", "import", "settings", "window",
        "panel", "markup", "overlay", "capture", "history", "search", "paste", "folder", "version", "summary",
    ]
    static let rareWord = "quartz"
    static let accentedVocabulary = [
        "ação", "informação", "reunião", "não", "São", "Paulo", "configuração", "título", "área", "você",
        "também", "até", "versão", "é", "às", "opção", "atenção", "câmera", "médico", "coração",
        "Reunião", "avaliação", "prática", "número", "histórico", "só", "relatório", "orçamento", "ênfase", "atenção",
    ]
    static let sourceApps = ["Safari", "Notes", "Xcode", "Mail", "Terminal"]
    static let pictureSizes = [
        CGSize(width: 2560, height: 1600), CGSize(width: 2560, height: 1600),
        CGSize(width: 800, height: 600), CGSize(width: 800, height: 600),
    ]
    static let imagePercent = 20
    static let firstDate = Date(timeIntervalSince1970: 1_767_225_600)

    static func write(count: Int, seed: UInt64, corpus: Corpus = .ascii, to directory: URL) throws {
        var random = LCG(seed: seed)
        let files = directory.appending(path: "files", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        var pictures: [Data] = []
        for size in pictureSizes {
            pictures.append(try renderPicture(size, &random))
        }
        var items: [CaptureItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            let date = firstDate.addingTimeInterval(Double(index) * 60)
            let id = randomID(&random)
            let app = sourceApps[random.below(sourceApps.count)]
            if random.below(100) < imagePercent {
                let picture = pictures[random.below(pictures.count)]
                let name = "\(id.uuidString).png"
                try picture.write(to: files.appending(path: name))
                items.append(CaptureItem(
                    id: id, kind: .screenshot, createdAt: date, lastUsedAt: date, copyCount: 1, pinned: false,
                    text: nil, fileName: name, sourceApp: app, sourceBundleID: nil, contentHash: hash(picture)
                ))
            } else {
                let text = makeText(for: corpus, index: index, &random)
                items.append(CaptureItem(
                    id: id, kind: .text, createdAt: date, lastUsedAt: date, copyCount: 1 + random.below(5),
                    pinned: false, text: text, fileName: nil, sourceApp: app, sourceBundleID: nil,
                    contentHash: hash(Data(text.utf8))
                ))
            }
        }
        try JSONEncoder().encode(items).write(to: directory.appending(path: "history.json"))
    }

    static let mixedVocabularies: [[String]] = [
        accentedVocabulary,
        ["привет", "мир", "отчёт", "проект", "встреча", "бюджет", "клиент", "сервер", "резервная", "копия", "окно",
         "панель", "история", "поиск", "файл", "таблица", "команда", "срок", "договор", "поездка"],
        ["日本語", "テキスト", "報告書", "会議", "予算", "設計", "確認", "メモ", "草稿", "顧客", "更新", "計画", "出張",
         "昼食", "契約", "画面", "履歴", "検索", "貼り付け", "フォルダ"],
        ["مرحبا", "العالم", "تقرير", "مَرْحَبًا", "اجتماع", "ميزانية", "عميل", "خادم", "نسخة", "احتياطية", "نافذة", "لوحة",
         "سجل", "بحث", "ملف", "جدول", "فريق", "موعد", "عقد", "رحلة"],
        ["नमस्ते", "दुनिया", "रिपोर्ट", "परियोजना", "बैठक", "बजट", "ग्राहक", "सर्वर", "बैकअप", "खिड़की", "पैनल", "इतिहास", "खोज",
         "फ़ाइल", "तालिका", "टीम", "अनुबंध", "यात्रा", "संस्करण", "सारांश"],
        ["😀", "👍", "🎉", "🔥", "✅", "📎", "📷", "💡", "🚀", "❤️", "👨‍👩‍👧", "🇧🇷", "👍🏽", "😂", "🙏"],
    ]

    private static func makeText(for corpus: Corpus, index: Int, _ random: inout LCG) -> String {
        switch corpus {
        case .ascii: makeText(index: index, &random)
        case .mixed: makeMixedText(index: index, &random)
        }
    }

    private static func makeMixedText(index: Int, _ random: inout LCG) -> String {
        let words = mixedVocabularies[random.below(mixedVocabularies.count)]
        let target = 20 + random.below(3981)
        var text = "#\(index)"
        var length = text.count
        while length < target {
            let word = words[random.below(words.count)]
            text += " " + word
            length += word.count + 1
        }
        return text
    }

    private static func makeText(index: Int, _ random: inout LCG) -> String {
        let target = 20 + random.below(3981)
        var text = "#\(index)"
        var length = text.count
        while length < target {
            let word = random.below(4000) == 0 ? rareWord : vocabulary[random.below(vocabulary.count)]
            text += " " + word
            length += word.count + 1
        }
        return String(text.prefix(target))
    }

    private static func renderPicture(_ size: CGSize, _ random: inout LCG) throws -> Data {
        let width = Int(size.width)
        let height = Int(size.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw BenchError.render }
        for _ in 0..<80 {
            let red = unit(&random)
            let green = unit(&random)
            let blue = unit(&random)
            context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
            context.fill(CGRect(
                x: CGFloat(random.below(width)), y: CGFloat(random.below(height)),
                width: CGFloat(random.below(width / 3) + 1), height: CGFloat(random.below(height / 3) + 1)
            ))
        }
        guard let image = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { throw BenchError.render }
        return png
    }

    private static func unit(_ random: inout LCG) -> CGFloat {
        CGFloat(random.below(256)) / 255
    }

    private static func randomID(_ random: inout LCG) -> UUID {
        var bytes = UUID().uuid
        withUnsafeMutableBytes(of: &bytes) { buffer in
            for index in buffer.indices {
                buffer[index] = UInt8(truncatingIfNeeded: random.next())
            }
        }
        return UUID(uuid: bytes)
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }
}
