import Foundation
import Testing
@testable import OctoPrep

private func spell(_ syllables: [String], _ rules: [String]) throws -> Script {
    try project(syllables: syllables, rules: rules.map(Rule.init))
}

/// Each case follows librime's calculus.cc, algebra.cc and spelling.cc.
@Suite struct AlgebraTests {
    /// Fuzzy groups (模糊音): a group's rules make fuzzy spellings tagged
    /// with its bit; groups combine; a derivation another one makes useless
    /// (fewer groups, as good) goes; the exact spelling stays as it was.
    @Test func fuzzyGroupsTagTheirSpellings() throws {
        let zh = [try Rule("derive/^zh/z"), try Rule("derive/^z([^h]*)/zh$1")]
        for r in zh { r.fuzzyGroup = 1 }
        let eng = [try Rule("derive/eng$/en"), try Rule("derive/en$/eng")]
        for r in eng { r.fuzzyGroup = 2 }
        let abbrev = try Rule("abbrev/^([a-z]).+$/$1")
        let s = try project(syllables: ["zhong", "zong", "zheng"], rules: zh + eng + [abbrev])
        let fuzzy = SpellingProperties(type: .fuzzy, credibility: log(0.5))
        #expect(s["zong"]?[Origin("zhong", fuzzy: 1)] == fuzzy, "zong spells zhong, with z = zh")
        #expect(s["zong"]?["zong"] == SpellingProperties(), "and zong exactly, as before")
        #expect(s["zong"]?["zhong"] == nil, "never zhong without a group")
        #expect(s["zen"]?[Origin("zheng", fuzzy: 3)] == SpellingProperties(type: .fuzzy, credibility: 2 * log(0.5)),
                "zen spells zheng only with both groups")
        #expect(s["z"]?[Origin("zhong", fuzzy: 1)] == nil && s["z"]?["zhong"] != nil,
                "the abbreviation z of zhong needs no group: the one through zong goes")
    }

    @Test func xformReplacesEveryMatch() throws {
        #expect(Set(try spell(["banana"], ["xform/a/o/"]).keys) == ["bonono"])
    }

    @Test func aMissingTrailingSeparatorIsFine() throws {
        #expect(Set(try spell(["banana"], ["xform/a/o"]).keys) == ["bonono"])
    }

    @Test func deriveKeepsTheOriginal() throws {
        let s = try spell(["zhi"], ["derive/^zh/z/"])
        #expect(Set(s.keys) == ["zhi", "zi"])
        #expect(s["zi"]?["zhi"] == SpellingProperties())
    }

    @Test func abbreviationsAndFuzzySpellingsCarryPenalties() throws {
        let s = try spell(["zhong"], ["abbrev/^(zh).+$/$1/", "fuzz/^zh/z/"])
        #expect(s["zh"]?["zhong"] == SpellingProperties(type: .abbreviation, credibility: log(0.5)))
        #expect(s["zong"]?["zhong"] == SpellingProperties(type: .fuzzy, credibility: log(0.5)))
        // A fuzzy spelling of an abbreviation: the worse type, both penalties.
        #expect(s["z"]?["zhong"] == SpellingProperties(type: .abbreviation, credibility: 2 * log(0.5)))
    }

    @Test func theBestDerivationWins() throws {
        // "z" is reached as an abbreviation (log 0.5) and as a plain derivation (0).
        let s = try spell(["zi"], ["abbrev/^(z).+$/$1/", "derive/^zi$/z/"])
        #expect(s["z"]?["zi"] == SpellingProperties())
    }

    @Test func eraseNeedsAFullMatch() throws {
        #expect(Set(try spell(["ab", "abc"], ["erase/ab/"]).keys) == ["abc"])
        // regex_match tries every way to match the whole spelling.
        #expect(try spell(["ab"], ["erase/a|ab/"]).isEmpty)
    }

    @Test func xlitMapsCharacters() throws {
        #expect(Set(try spell(["zhōng①"], ["xlit/ō①/o7/"]).keys) == ["zhong7"])
    }

    @Test func badFormulasAreErrors() {
        #expect(throws: AlgebraError.self) { try Rule("xlit/ab/c/") }
        #expect(throws: AlgebraError.self) { try Rule("reorder/a/b/") }
        #expect(throws: AlgebraError.self) { try Rule("unknown/a/b/") }
        #expect(throws: AlgebraError.self) { try Rule("xform/(/b/") }
        #expect(throws: AlgebraError.self) { try Rule("xform") }
    }

    @Test func boostCaseEscapes() throws {
        #expect(Set(try spell(["ab;cd"], ["xform/^([a-z]+);([a-z])([a-z])$/$1\\u$2$3/"]).keys) == ["abCd"])
        #expect(Set(try spell(["ab;cd"], ["xform/^([a-z]+);([a-z]+)$/$1\\U$2\\E!/"]).keys) == ["abCD!"])
    }

    @Test func groupForms() throws {
        #expect(Set(try spell(["ab"], ["xform/^(a)(b)$/${2}${1}$&$$/"]).keys) == ["baab$"])
    }

    @Test func patternsMatchBytesAsBoostDoes() throws {
        // A class holding a three-byte character matches each of its bytes.
        #expect(Set(try spell(["a◯b"], ["xform/^([a-z◯]+)$/<$1>/"]).keys) == ["<a◯b>"])
        // `.` is one byte, so three of them span one three-byte character.
        #expect(Set(try spell(["◯"], ["xform/^...$/x/"]).keys) == ["x"])
    }

    @Test func aReplacementThatBreaksUTF8IsAnError() {
        #expect(throws: AlgebraError.self) { try spell(["◯"], ["xform/^./x/"]) }
    }

    /// 全拼's typo rule `zih` → zhi. Dropping it removes that spelling and
    /// leaves the syllable's own.
    @Test func droppingATypoRuleLosesOnlyItsSpellings() throws {
        let typo = "derive/([zcs])h([aeiu])$/$1$2h/"
        let keep = "derive/^zh/z/"
        var seen = Set<String>()
        let kept = schemeFormulas([typo, keep], dropping: [typo], seen: &seen)
        #expect(kept == [keep])
        #expect(seen == [typo])
        try requireDroppedRulesPresent([typo], seen: seen)

        let withTypo = try spell(["zhi"], [typo, keep])
        let without = try spell(["zhi"], kept)
        #expect(withTypo["zih"]?["zhi"] == SpellingProperties())
        #expect(without["zih"] == nil)
        #expect(without["zhi"]?["zhi"] == SpellingProperties())
        #expect(without["zi"]?["zhi"] == SpellingProperties())
        #expect(Set(withTypo.keys).subtracting(without.keys) == ["zih"])
    }

    @Test func aListedRuleMissingFromEverySchemeThrows() throws {
        var seen = Set<String>()
        let first = schemeFormulas(["derive/^zh/z/"], dropping: ["derive/ong$/on/"], seen: &seen)
        let second = schemeFormulas(["derive/ong$/on/"], dropping: ["derive/ong$/on/"], seen: &seen)
        #expect(first == ["derive/^zh/z/"])
        #expect(second.isEmpty)
        try requireDroppedRulesPresent(["derive/ong$/on/"], seen: seen)

        let missing = "derive/([zcs])h([aeiu])$/$1$2h/"
        #expect(throws: AlgebraError.self) {
            try requireDroppedRulesPresent([missing], seen: [])
        }
        do {
            try requireDroppedRulesPresent([missing], seen: [])
            Issue.record("a listed rule no scheme has must throw")
        } catch let error as AlgebraError {
            #expect(error.description == "data/wanxiang-typo-rules.txt names a rule 万象's algebra no longer has: \(missing); review the list")
        }
    }

    @Test func theDropListSkipsCommentsAndBlankLines() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typo-rules-\(UUID().uuidString).txt")
        try "# what it is\n\n\nderive/ong$/on/\n# trailing\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try loadDroppedRules(url.path) == ["derive/ong$/on/"])
    }
}
