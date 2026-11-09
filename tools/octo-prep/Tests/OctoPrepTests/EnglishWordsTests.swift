import Foundation
import Testing
@testable import OctoPrep

@Suite struct EnglishWordsTests {
    /// Writes `files` (name → text) to a fresh directory; returns its path.
    private func directory(_ files: [String: String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("english-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, text) in files { try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        return dir.path
    }

    private let dict = """
        ---
        name: test_english
        ...
        change\tchange\t900
        changes\tchanges\t400
        car\tcar\t2000
        cars\tcars\t600
        is\tis\t5000
        be\tbe\t4000
        news\tnews\t300
        new\tnew\t9000
        its\tits\t700
        it\tit\t9000
        data\tdata\t800
        datum\tdatum\t5
        window\twindow\t400
        windows\twindows\t100
        Windows\tWindows\t500
        best practices\tbestpractices\t20
        practice\tpractice\t300
        practices\tpractices\t80
        GitHub Actions\tGitHubActions\t6
        mp3\tmp3\t50

        """

    private let infl = """
        change N: changes
        change V: changed | changing | changes
        car N: cars, cares!< 1
        cars N?: carses
        be V: was, wast 2 | were | been | being | am | are, art 2 | is | are
        news N: newses
        new V?: newed | newing | news
        it N: its
        datum N: data
        window N: windows
        practice N: practices
        practice V: practiced | practicing | practices
        action N: actions
        chair N: chairs~

        """

    @Test func inflectionsAreReadAsAGIDLaysThemOut() throws {
        let dir = try directory(["infl.txt": infl])
        let agid = try EnglishInflections(path: "\(dir)/infl.txt")
        #expect(agid.bases["changes"] == ["change"])
        #expect(agid.bases["is"] == ["be"])
        #expect(agid.bases["cares"] == ["car"])
        #expect(agid.bases["chairs"] == nil, "a form tagged ~ is only a slight chance")
        #expect(agid.bases["news"] == nil, "new V? is a part of speech AGID was unsure of")
        #expect(agid.headwords.contains("news") && !agid.headwords.contains("cars"),
                "a lemma only where the part of speech is known")
    }

    @Test func pluralsAndThirdPersonFormsAreLeftOut() throws {
        let dir = try directory(["en.dict.yaml": dict, "infl.txt": infl])
        let words = try EnglishWords(path: "\(dir)/en.dict.yaml",
                                     inflections: EnglishInflections(path: "\(dir)/infl.txt"))
        let lines = Set(words.tsv().split(separator: "\n").map(String.init))
        let codes = Set(lines.compactMap { $0.hasPrefix("#") ? nil : $0.split(separator: "\t").first.map(String.init) })
        #expect(!codes.contains("changes") && !codes.contains("cars") && !codes.contains("is"),
                "plurals and third-person -s forms go")
        #expect(codes.isSuperset(of: ["change", "car", "be", "news", "its", "data"]),
                "lemmas stay, and so do its (kept by name) and data (its base, datum, is rare)")
        #expect(lines.contains("windows\t500\tWindows"), "a capitalized form is a name and stays; windows goes, and its weight with it")
        #expect(!codes.contains("bestpractices"), "a lowercase phrase goes with its last word")
        #expect(codes.contains("githubactions"), "a capitalized phrase stays")
        #expect(!codes.contains("mp3"), "a code must be letters")
    }

    @Test func withoutAGIDNothingIsFiltered() throws {
        let dir = try directory(["en.dict.yaml": dict])
        let words = try EnglishWords(path: "\(dir)/en.dict.yaml")
        #expect(words.tsv().contains("\nchanges\t400\tchanges\n"))
    }
}
