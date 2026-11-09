import Foundation
import Testing
@testable import OctoPrep

/// The pinned upstream files, if tools/fetch-wanxiang.sh has fetched them.
private let wanxiangDirectory: String? = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard let lock = try? String(contentsOf: root.appendingPathComponent("data/wanxiang.lock"), encoding: .utf8),
          let tag = lock.split(separator: "\n").first(where: { $0.hasPrefix("tag ") })?.dropFirst(4)
    else { return nil }
    let directory = root.appendingPathComponent(".data/wanxiang/\(tag)").path
    return FileManager.default.fileExists(atPath: "\(directory)/wanxiang_algebra.yaml") ? directory : nil
}()

/// 万象's full-pinyin rules over the syllables of its character table, plus
/// the neutral-tone "a": what a user typing full pinyin gets.
private func fullPinyin() throws -> (syllables: [String], script: Script) {
    let directory = wanxiangDirectory!
    var syllables: Set<String> = ["a"]
    try DictFile(path: "\(directory)/dicts/zi.dict.yaml").forEachRow { row in
        for part in (row.code ?? "").split(separator: " ") {
            if let syllable = Pinyin.syllable(String(part)) { syllables.insert(syllable.toned) }
        }
    }
    let algebra = try YAML.parse(String(contentsOfFile: "\(directory)/wanxiang_algebra.yaml", encoding: .utf8))
    let rules = try algebra.at("base/全拼/__append")!.strings!.map(Rule.init)
    let sorted = syllables.sorted()
    return (sorted, try project(syllables: sorted, rules: rules))
}

@Suite(.enabled(if: wanxiangDirectory != nil, "run tools/fetch-wanxiang.sh first"))
struct WanxiangTests {
    static let (syllables, script) = try! fullPinyin()
    var script: Script { Self.script }

    @Test func plainAndToneDigitSpellings() {
        #expect(script["zhong"]?["zhōng"] == SpellingProperties())
        #expect(script["zhong7"]?["zhōng"] == SpellingProperties())     // tone 1 is typed 7
        #expect(script["zhong8"]?["zhōng"] == nil)
    }

    @Test func theNeutralToneIsTypedZero() {
        #expect(script["a0"]?["a"] == SpellingProperties())
        #expect(script["a"]?["a"] == SpellingProperties())
    }

    @Test func initialsAbbreviate() {
        #expect(script["zh"]?["zhōng"] == SpellingProperties(type: .abbreviation, credibility: log(0.5)))
        #expect(script["z"]?["zhōng"] == SpellingProperties(type: .abbreviation, credibility: log(0.5)))
    }

    /// Still in 万象's algebra, as normal spellings. octo-prep drops this block
    /// (`data/wanxiang-typo-rules.txt`); these pin the upstream text.
    @Test func typoTolerantSpellingsAreNormal() {
        #expect(script["zhon"]?["zhōng"] == SpellingProperties())
        #expect(script["hzong"]?["zhōng"] == SpellingProperties())
        #expect(script["zhogn"]?["zhōng"] == SpellingProperties())
    }

    /// Every rule on the pinned drop list is in 全拼, and 小鹤双拼 has none.
    @Test func thePinnedTypoListIsInQuanpinOnly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let listed = try loadDroppedRules(root.appendingPathComponent("data/wanxiang-typo-rules.txt").path)
        let algebra = try YAML.parse(String(contentsOfFile: "\(wanxiangDirectory!)/wanxiang_algebra.yaml", encoding: .utf8))
        let full = Set(algebra.at("base/全拼/__append")!.strings!)
        let flypy = Set(algebra.at("base/小鹤双拼/__append")!.strings!)
        #expect(listed.count == 38)
        #expect(listed.isSubset(of: full))
        #expect(listed.isDisjoint(with: flypy))
    }

    @Test func umlautSpellings() {
        #expect(script["lve"]?["lüè"] == SpellingProperties())
        #expect(script["lue"]?["lüè"] == SpellingProperties())
        #expect(script["nv"]?["nǚ"] == SpellingProperties())
        #expect(script["nu"]?["nǚ"] == nil)
    }

    /// Every syllable is typed as its own letters, except the three 万象
    /// spells otherwise: ng as eng, n as en, m as me.
    @Test func everySyllableSpellsItself() {
        let missing = Self.syllables.filter { syllable in
            let plain = Pinyin.syllable(syllable)!.plain
            return script[plain]?[syllable] == nil && !["ng", "n", "m"].contains(plain)
        }
        #expect(missing.isEmpty, "not spelled by their own letters: \(missing)")
        #expect(script["eng"]?.keys.contains { $0.fuzzy == 0 && Pinyin.syllable($0.syllable)?.plain == "ng" } == true)
    }
}
