import Foundation
import Testing
@testable import OctoPrep

@Suite struct YAMLTests {
    @Test func algebraShapedDocument() throws {
        let doc = try YAML.parse("""
            # comment
            base:
              全拼:
                __append:
                  - xform/Ⅰ//  #marker
                  - derive/(.+)(\\d)/$1/
              双拼:
                __append:
                  - xlit/①②③④/7890
            """)
        #expect(doc.at("base/全拼/__append")?.strings == ["xform/Ⅰ//", "derive/(.+)(\\d)/$1/"])
        #expect(doc.at("base/双拼/__append")?.strings == ["xlit/①②③④/7890"])
    }

    @Test func dictionaryHeader() throws {
        let doc = try YAML.parse("""
            ---
            name: wanxiang
            version: "LTS"
            sort: by_weight  #comment
            import_tables:
              - dicts/zi            #必要
              #- dicts/yixue
              - dicts/jichu
            columns: [text, code, weight]
            ...
            not: [read
            """)
        #expect(doc["name"]?.string == "wanxiang")
        #expect(doc["version"]?.string == "LTS")
        #expect(doc["sort"]?.string == "by_weight")
        #expect(doc["import_tables"]?.strings == ["dicts/zi", "dicts/jichu"])
        #expect(doc["columns"]?.strings == ["text", "code", "weight"])
    }

    @Test func aSequenceAtItsKeysIndentation() throws {
        #expect(try YAML.parse("a:\n- x\n- y\nb: z")["a"]?.strings == ["x", "y"])
    }

    @Test func unsupportedSyntaxIsAnErrorNamingTheLine() {
        #expect { try YAML.parse("a:\n  - b: c") } throws: { ($0 as? YAMLError)?.line == 2 }
        #expect { try YAML.parse("a: &anchor b") } throws: { ($0 as? YAMLError)?.line == 1 }
        #expect { try YAML.parse("a:\n\t- b") } throws: { ($0 as? YAMLError)?.line == 2 }
    }
}

@Suite struct PinyinTests {
    @Test(arguments: [("zhōng", "zhong", 1), ("lǜ", "lv", 4), ("nǚ", "nv", 3), ("lüè", "lve", 4),
                      ("a", "a", 0), ("m̄", "m", 1), ("ḿ", "m", 2), ("ǹg", "ng", 4)])
    func splitsTones(text: String, plain: String, tone: Int) {
        let syllable = Pinyin.syllable(text)
        #expect(syllable?.plain == plain)
        #expect(syllable?.tone == tone)
    }

    @Test func normalizesToNFC() {
        #expect(Pinyin.syllable("zho\u{0304}ng")?.toned == "zhōng")
    }

    @Test func rejectsWhatIsNotPinyin() {
        for text in ["", "A", "zh ong", "a1", "ê", "ǎà"] {
            #expect(Pinyin.syllable(text) == nil, "\(text)")
        }
    }
}

@Suite struct DictReaderTests {
    private func dict(_ text: String) throws -> DictFile {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("octo-prep-\(UUID().uuidString).dict.yaml").path
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }
        return try DictFile(path: path)
    }

    @Test func rowsCommentsAndColumns() throws {
        let file = try dict("""
            # Rime dictionary
            ---
            name: t
            ...
            阿爸\tā bà\t716
            # a comment
            阿坝\tā bà
            株木琅玛\tzhū mù láng mǎ\t205\t有声

            """)
        var rows: [DictFile.Row] = []
        file.forEachRow { rows.append($0) }
        #expect(rows.map(\.text) == ["阿爸", "阿坝", "株木琅玛"])
        #expect(rows.map(\.line) == [5, 7, 8])
        #expect(rows[1].weight == nil)
        #expect(rows[2].extraColumns == 1)
    }

    @Test func noCommentTurnsCommentsOff() throws {
        let file = try dict("---\nname: t\n...\n# no comment\n#\thash\t1\n")
        var texts: [String] = []
        file.forEachRow { texts.append($0.text) }
        #expect(texts == ["#"])
    }

    @Test func aMissingHeaderEndIsAnError() {
        #expect(throws: AlgebraError.self) { try dict("---\nname: t\n阿\tā\t1\n") }
    }

    @Test func weightsReadAsStodReadsThem() {
        #expect(Weight.read("716") == .number(716))
        #expect(Weight.read("1.5e3") == .number(1500))
        #expect(Weight.read("45N") == .prefix(45))
        #expect(Weight.read("10s") == .prefix(10))
        #expect(Weight.read("1e") == .prefix(1))
        #expect(Weight.read("abc") == .notANumber)
        #expect(Weight.read("50%") == .scaled)
    }
}
