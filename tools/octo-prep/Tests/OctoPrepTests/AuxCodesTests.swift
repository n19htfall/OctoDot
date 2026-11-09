import Foundation
import Testing
@testable import OctoPrep

@Suite struct AuxCodesTests {
    @Test func cellsGiveTheirTrailingCodes() {
        #expect(AuxCodes.codes(inCell: "口可 kk") == ["kk"])
        #expect(AuxCodes.codes(inCell: "爫夊vw｜心夊xw") == ["vw", "xw"])
        #expect(AuxCodes.codes(inCell: " pw") == ["pw"])
        #expect(AuxCodes.codes(inCell: "wp,wy") == ["wp", "wy"])
        #expect(AuxCodes.codes(inCell: "丨一aa｜{艹}ck｜丨一aa") == ["aa", "ck"])
        #expect(AuxCodes.codes(inCell: "{艹}") == [])
        #expect(AuxCodes.codes(inCell: "") == [])
    }

    @Test func quotedFieldsKeepTheirCommas() {
        #expect(AuxCodes.fields("餲,食曷 uh,\"wp,wy\",,x") == ["餲", "食曷 uh", "wp,wy", "", "x"])
        #expect(AuxCodes.fields("a,\"say \"\"hi\"\"\"") == ["a", "say \"hi\""])
    }

    @Test func aTableNormalizes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("aux_code.csv").path
        try "#,万象,墨奇\n呵,口可 kk,口可 kk\n愛,爫夊 vw,\"wp,wy\"\nab,x y,z\n".write(toFile: path, atomically: true,
                                                                                  encoding: .utf8)
        let aux = try AuxCodes(path: path)
        #expect(aux.schemes == ["wanxiang", "moqi"])
        #expect(aux.tsv() == "# char\twanxiang\tmoqi\n# names\t万象\t墨奇\n呵\tkk\tkk\n愛\tvw\twp wy\n")
        #expect(aux.issues.map(\.reason) == ["not one character"])
    }
}
