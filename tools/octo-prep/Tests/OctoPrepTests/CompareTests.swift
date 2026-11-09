import Testing
@testable import OctoPrep

@Suite struct CompareTests {
    private func report(tag: String, entries: Int, noWeight: Int) -> Report {
        let issue = Report.Issue(reason: "no weight; 0 is used", dropped: false, count: noWeight, examples: [])
        return Report(upstream: .init(repo: "r", tag: tag, commit: tag), sources: [
            .init(file: "dicts/jichu.dict.yaml", rows: entries, kept: entries, duplicates: 0,
                  issues: noWeight > 0 ? [issue] : []),
        ], duplicatesMerged: 0, entries: entries, syllables: 1590, plainSyllables: 419, spellings: [], aux: nil, charsets: nil, lexicons: nil, outputs: [:])
    }

    @Test func reportsOnlyWhatMoved() {
        let lines = compare(report(tag: "v1", entries: 100, noWeight: 2), report(tag: "v2", entries: 103, noWeight: 0))
        #expect(lines.contains("  upstream: v1 → v2"))
        #expect(lines.contains("  entries: 100 → 103 (+3)"))
        #expect(lines.contains("  dicts/jichu.dict.yaml \"no weight; 0 is used\": 2 → 0 (-2)"))
        #expect(!lines.contains { $0.contains("syllables") })
    }

    @Test func identicalReportsHaveNoLines() {
        #expect(compare(report(tag: "v1", entries: 1, noWeight: 0), report(tag: "v1", entries: 1, noWeight: 0)).isEmpty)
    }
}
