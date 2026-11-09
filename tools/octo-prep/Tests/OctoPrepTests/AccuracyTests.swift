import Foundation
import Testing
@testable import OctoPrep

@Suite struct AccuracyTests {
    /// Readings for a few characters, as the prepared lexicons would give them.
    private func readings() -> AccuracySet.Readings {
        var r = AccuracySet.Readings()
        r.plain = ["ke", "ken", "neng", "eng", "xi", "an", "xian", "fang", "gai", "ge", "ci", "li", "bai",
                   "lao", "shi", "bei", "jing", "nan", "du", "dou", "yi"]
        let toned = ["kě": "ke", "néng": "neng", "xī": "xi", "ān": "an", "fāng": "fang", "gě": "ge", "gài": "gai",
                     "cí": "ci", "lǐ": "li", "bái": "bai", "lǎo": "lao", "shī": "shi", "běi": "bei", "jīng": "jing",
                     "nán": "nan", "dū": "du", "dōu": "dou", "yī": "yi"]
        let lexicon = """
            #lexicon\tcore\t万象基础\ton
            # text\tcode\tweight\tsource
            可能\tkě néng\t100\tx
            西安\txī ān\t100\tx
            盖茨\tgě cí\t10\tx
            盖\tgài\t10\tx
            李白\tlǐ bái\t10\tx
            老师\tlǎo shī\t10\tx
            北京\tběi jīng\t10\tx
            南都\tnán dū\t10\tx
            都\tdōu\t10\tx
            李·白\tlǐ bái\t1\tx
            一\tyī\t1\tx
            """
        AccuracySet.addLexicon(Data(lexicon.utf8), toned: toned, wanted: ["盖茨", "南都", "北京", "李白"], to: &r)
        return r
    }

    @Test func splitsByTheCharactersReadings() {
        let r = readings()
        #expect(AccuracySet.split("可能", "keneng", r) == ["ke", "neng"])    // not ken eng
        #expect(AccuracySet.split("西安", "xian", r) == ["xi", "an"])
        #expect(AccuracySet.split("西安", "xiang", r) == nil)
        #expect(AccuracySet.split("可能", "keneng", r) != nil)
        #expect(r.chars["盖"] == ["ge", "gai"])                              // from every word that has it
        #expect(r.words["李白"] == [["li", "bai"]])                           // not from 李·白, which has a mark
    }

    @Test func writesTheApostropheATypistTypes() {
        let plain: Set<String> = ["xi", "an", "xian", "fang"]
        #expect(AccuracySet.pinyinField(["xi", "an"], plain: plain) == "xi'an")
        #expect(AccuracySet.pinyinField(["fang", "an"], plain: plain) == "fang an")
    }

    @Test func readsTHUOCLInOrderOfUse() {
        let text = "\u{FEFF}北京\t 50\r老师 \t 900\r\n李白\t50\n\n"
        #expect(AccuracySet.thuocl(text) == ["老师", "北京", "李白"])   // ties keep the file's order
    }

    @Test func takesOnlyWordsAndSetsAsideWhatItCannotRead() {
        let r = readings()
        let ppd = AccuracySet.phrasePinyin("""
            # version
            盖茨: gài cí
            李白: lǐ bái
            老师: lǎo shī
            北京: běi jīng
            南都: nán dōu
            一一: yī yī
            """, plain: r.plain)
        let thuocl = "盖茨\t9\n新一\t8\n李白\t7\n北京\t6\n老师\t5\n南都\t4\n一一\t3\n"
        let gold = "# gold\n可能\tkeneng\n西安\txiang\n"
        let set = AccuracySet.build(goldWords: gold, goldSentences: "", thuocl: [("names", thuocl)],
                                    phrasePinyin: ppd, readings: r, perCategory: 2)
        #expect(set.words.map(\.text) == ["可能", "李白", "北京"])         // two names, after the gold word
        #expect(set.words[1].syllables == ["li", "bai"])
        let reasons = Dictionary(uniqueKeysWithValues: set.review.map { ($0.text, $0.reason) })
        #expect(reasons["西安"]?.contains("does not split") == true)       // a reading that does not fit
        #expect(reasons["盖茨"]?.contains("万象 ge ci") == true)            // the sources disagree
        #expect(reasons["新一"]?.contains("not a word") == true)           // a fragment
        #expect(reasons["老师"] == nil)                                     // past the limit: not looked at
    }
}
