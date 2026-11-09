import Foundation
import Testing
@testable import OctoPrep

@Suite struct GrammarTests {
    @Test func theKeyEncodingRoundTrips() {
        // ASCII, the CJK block (with and without a zero low byte: 一 is
        // U+4E00), outside it (　 U+3000, 𠀀 U+20000), and U+0000.
        let scalars: [Unicode.Scalar] = ["a", "$", "中", "一", "\u{9FFF}", "\u{4000}", "\u{3000}", "\u{20000}", "\u{0}"]
        for s in scalars {
            let bytes = GrammarModel.encode([s])
            #expect(GrammarModel.decode(bytes) == [s], "U+\(String(s.value, radix: 16))")
        }
        #expect(GrammarModel.encode(["中"]) == [0x8E, 0x2D])           // (0x4E + 0x40), 0x2D
        #expect(GrammarModel.encode(["一"]) == [0xE1, 0x8E])           // a zero low byte is escaped
        #expect(GrammarModel.decode(GrammarModel.encode(Array("我们一起$".unicodeScalars))) == Array("我们一起$".unicodeScalars))
        #expect(GrammarModel.decode([0x8E]) == nil)                    // cut short
        #expect(GrammarModel.decode([0xF0]) == nil)                    // no such lead byte
    }

    @Test func readsTheSchemasSettings() throws {
        let schema = """
            schema:
              name: 万象
            translator:
              dictionary: wanxiang
              max_homophones: 8
            grammar:
              language: wanxiang-lts-zh-hans
              collocation_max_length: 6
              collocation_min_length: 2
              collocation_penalty: -14
              non_collocation_penalty: -6
              weak_collocation_penalty: -100
              rear_penalty: -18
            # 主翻译器
            key_binder:
              bindings: [a, b]
            """
        let (language, s, homophones) = try GrammarModel.schema(schema)
        #expect(language == "wanxiang-lts-zh-hans" && homophones == 8)
        #expect(s.maxLength == 6 && s.minLength == 2 && s.span == 5)
        #expect(s.collocationPenalty == -14 && s.nonCollocationPenalty == -6 && s.weakCollocationPenalty == -100 &&
                s.rearPenalty == -18)
        #expect(throws: (any Error).self) { try GrammarModel.schema("translator:\n  max_homophones: 8\n") }
        let tsv = GrammarModel.settingsTSV(language: language, settings: s, homophones: homophones, fileSize: 1024)
        #expect(tsv.contains("language\twanxiang-lts-zh-hans\n") && tsv.contains("file_size\t1024\n") &&
                tsv.contains("max_homophones\t8\n"))
    }

    @Test func checksAGramFilesHeader() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gram-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var good = Data("Rime::Grammar/1.0".utf8)
        good.append(Data(count: 36 - good.count))
        for v: UInt32 in [256, 4] { withUnsafeBytes(of: v.littleEndian) { good.append(contentsOf: $0) } }
        good.append(Data(count: 256 * 4))
        let path = dir.appendingPathComponent("a.gram").path
        try good.write(to: URL(fileURLWithPath: path))
        #expect(try GrammarModel.check(path) == good.count)
        try good.prefix(good.count - 4).write(to: URL(fileURLWithPath: path))   // the array runs past the end
        #expect(throws: (any Error).self) { try GrammarModel.check(path) }
        var other = good
        other.replaceSubrange(0..<4, with: Data("Nope".utf8))
        try other.write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) { try GrammarModel.check(path) }
    }

    @Test func splitsTheCorpusAsTheBenchmarkDoes() {
        let text = """
            链接：https://www.zhihu.com/question/1
            一家三口候补车票，八岁小孩被分到不同车厢。我就不明白了：两个大人座位相连
            他说“这是不可能的事情”然后走了，价格是三点五元
            北京、上海和广州都很大，读了《红楼梦》这本书
            """
        #expect(AccuracySet.corpusSentences(text) == ["一家三口候补车票", "八岁小孩被分到不同车厢", "这是不可能的事情", "价格是三点五元"])
    }

    @Test func readsASentenceLikePypinyin() {
        var r = AccuracySet.Readings()
        r.plain = ["chang", "zhang", "da", "le", "liao"]
        r.chars = ["长": ["chang", "zhang"], "大": ["da"], "了": ["le", "liao"]]
        r.usual = ["长": ("chang", 9), "大": ("da", 9), "了": ("le", 9)]
        let ppd: [String: [[String]]] = ["长大": [["zhang", "da"]]]
        #expect(AccuracySet.readSentence("长大了", ppd: ppd, r) == ["zhang", "da", "le"])   // the word's reading, then the usual one
        #expect(AccuracySet.readSentence("长了", ppd: ppd, r) == ["chang", "le"])
        #expect(AccuracySet.readSentence("长X", ppd: ppd, r) == nil)
    }
}
