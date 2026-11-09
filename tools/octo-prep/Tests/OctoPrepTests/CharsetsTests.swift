import Foundation
import Testing
@testable import OctoPrep

@Suite struct CharsetsTests {
    private func fixture(extra: String) throws -> (dir: URL, extra: String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unihan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try """
            # Unicode Version 18.0.0
            U+4E2D\tkRSUnicode\t2.3
            U+662F\tkRSUnicode\t72.5
            U+6630\tkRSUnicode\t72.5
            U+8BF6\tkRSUnicode\t149.8
            U+5F8C\tkRSUnicode\t60.6
            U+4E2D\tkTotalStrokes\t4
            """.write(to: dir.appendingPathComponent("Unihan_IRGSources.txt"), atomically: true, encoding: .utf8)
        try """
            U+4E2D\tkTGH\t2013:24
            U+4E2D\tkGB0\t5448
            U+4E2D\tkBigFive\tA4A4
            U+662F\tkTGH\t2013:690
            U+662F\tkGB0\t4239
            U+8BF6\tkGB0\t7949
            U+5F8C\tkGB0\t2868
            U+5F8C\tkBigFive\tAB E1
            """.write(to: dir.appendingPathComponent("Unihan_OtherMappings.txt"), atomically: true, encoding: .utf8)
        let path = dir.appendingPathComponent("extra.txt").path
        try extra.write(toFile: path, atomically: true, encoding: .utf8)
        return (dir, path)
    }

    @Test func setsComeFromTheirFields() throws {
        let (dir, extra) = try fixture(extra: "# comment\n诶\tan interjection\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        let c = try Charsets(directory: dir.path, extra: extra)
        #expect(c.version == "18.0.0")
        #expect(c.tsv() == """
            # char\tsets
            中\than tgh gb2312 big5
            後\than gb2312 big5
            是\than tgh gb2312
            昰\than
            诶\than gb2312 extra

            """)
        let r = c.report(used: ["中", "昰", "·"])
        #expect(r.lexiconCharacters == 3 && r.lexiconCharactersInNoSet == 1)
        #expect(r.lexiconCharactersBySet["han"] == 2 && r.lexiconCharactersBySet["tgh"] == 1)
    }

    @Test func extrasMustBeIdeographsOutsideTheTable() throws {
        let (dir, extra) = try fixture(extra: "中\talready there\n")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: AlgebraError.self) { try Charsets(directory: dir.path, extra: extra) }
        try "·\tnot an ideograph\n".write(toFile: extra, atomically: true, encoding: .utf8)
        #expect(throws: AlgebraError.self) { try Charsets(directory: dir.path, extra: extra) }
    }
}
