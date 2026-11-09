import Testing
@testable import OctoPrep

@Suite struct MarkTests {
    @Test func marksTakeNoSyllable() {
        #expect(alignedCode("李·卡斯利", ["lǐ", "kǎ", "sī", "lì"]) == "lǐ - kǎ sī lì")
        #expect(alignedCode("马丁·路德·金", ["mǎ", "dīng", "lù", "dé", "jīn"]) == "mǎ dīng - lù dé - jīn")
        #expect(alignedCode("中国", ["zhōng", "guó"]) == "zhōng guó")
        #expect(alignedCode("中国人", ["zhōng", "guó"]) == nil)
        #expect(alignedCode("中·国·", ["zhōng"]) == nil)
    }
}
