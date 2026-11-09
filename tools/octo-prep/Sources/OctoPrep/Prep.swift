import CryptoKit
import Foundation

/// What octo-prep reads and where it writes.
public struct PrepOptions {
    public var source: String           // the pinned upstream files (.data/wanxiang/<tag>)
    public var output: String           // where the normalized sources go
    public var lock: String?            // data/wanxiang.lock, recorded in the report
    public var unihan: String?          // the pinned Unihan tables (.data/unihan/<version>)
    public var dailyExtra: String?      // data/daily-extra.txt
    public var grammar: String?         // the pinned grammar model (.data/grammar/<language>.gram)
    public var agid: String?            // AGID's infl.txt (.data/agid): which English forms are inflections
    /// Rules to leave out of every scheme's own list (data/wanxiang-typo-rules.txt):
    /// 全拼's typo spellings. Fuzzy groups are not filtered. Nil leaves every rule.
    public var droppedRules: String?
    public var schema = "wanxiang.schema.yaml"
    public var manifest = "wanxiang.dict.yaml"
    public var algebra = "wanxiang_algebra.yaml"
    public var auxCodes = "custom/aux_code.csv"
    public var english = "dicts/en.dict.yaml"
    /// Spelling schemes: a path into the algebra file, the id that names its
    /// output (spellings.<id>.tsv), and what its keys are: "typed" (letters
    /// spelling pinyin) or "syllables" (codes for syllables, as shuangpin's,
    /// which spell no pinyin). The preedit shows the keys typed, by syllable,
    /// in both. The display name is the algebra's own key ("小鹤双拼").
    public var schemes: [(path: String, name: String, preedit: String)] = [
        ("base/全拼", "fullpinyin", "typed"),
        ("base/小鹤双拼", "flypy", "syllables"),
    ]

    /// Fuzzy pinyin (模糊音): 万象's rule blocks, each a group the user turns
    /// on or off (docs/fuzzy-pinyin.md). Evaluated ahead of every scheme's
    /// rules (they rewrite toned pinyin, which the schemes' rules then turn
    /// into keys), every row tagged with the groups its derivation needed,
    /// bit i for the i-th; the id names it to the host ("z_zh": z = zh).
    public var fuzzy: [(path: String, id: String)] = [
        ("模糊音_z_zh", "z_zh"), ("模糊音_c_ch", "c_ch"), ("模糊音_s_sh", "s_sh"),
        ("模糊音_nl", "n_l"), ("模糊音_rl", "r_l"), ("模糊音_ry", "r_y"),
        ("模糊音_hf", "h_f"), ("模糊音_kg", "k_g"),
        ("模糊音_en_eng", "en_eng"), ("模糊音_in_ing", "in_ing"),
    ]

    /// Lexicon sets the user can switch on and off, each its own image beside
    /// the core: an id (lexicon.<id>.tsv), a name, the dictionaries it holds,
    /// and whether it is on unless the user turns it off. The manifest's other
    /// dictionaries form the core ("core", lexicon.tsv), always on.
    public var sets: [(id: String, name: String, tables: [String], on: Bool)] = [
        ("diming", "地名", ["dicts/diming"], true),
        ("mingren", "名人", ["dicts/mingren"], true),
        ("yiren", "艺人", ["dicts/yiren"], true),
    ]
    public var coreName = "万象基础"

    public init(source: String, output: String, lock: String? = nil, unihan: String? = nil) {
        self.source = source
        self.output = output
        self.lock = lock
        self.unihan = unihan
    }
}

/// The import report: what was read, what was kept, and why any row was left out.
public struct Report: Codable {
    public struct Upstream: Codable {
        public var repo: String?, tag: String?, commit: String?
    }
    public struct Issue: Codable {
        public var reason: String
        public var dropped: Bool    // false: the row was kept, with this noted
        public var count: Int
        public var examples: [String]
    }
    public struct Source: Codable {
        public var file: String
        public var rows: Int
        public var kept: Int
        public var duplicates: Int  // rows merged into an earlier identical entry
        public var issues: [Issue]
    }
    public struct Spellings: Codable {
        public var scheme: String
        public var file: String
        public var rules: Int
        public var spellings: Int
        public var rows: Int
        public var rowsByType: [String: Int]
        public var fuzzyRows: Int?
        public var droppedRules: Int?   // how many of the scheme's own rules were left out
    }
    public struct Aux: Codable {
        public var file: String
        public var rows: Int
        public var characters: Int
        public var charactersByScheme: [String: Int]
        public var issues: [Issue]
    }
    public struct English: Codable {
        public var file: String
        public var rows: Int
        public var codes: Int
        public var forms: Int
        public var skipped: [String: Int]
    }
    public struct LexiconSet: Codable {
        public var id: String
        public var name: String
        public var file: String
        public var entries: Int
        public var on: Bool
    }
    public struct Charsets: Codable {
        public var unicode: String
        public var characters: [String: Int]
        public var lexiconCharacters: Int
        public var lexiconCharactersBySet: [String: Int]
        public var lexiconCharactersInNoSet: Int
    }
    public var upstream: Upstream
    public var sources: [Source]
    public var duplicatesMerged: Int
    public var entries: Int
    public var syllables: Int
    public var plainSyllables: Int
    public var spellings: [Spellings]
    public var aux: Aux?
    public var english: English?
    public var charsets: Charsets?
    public var lexicons: [LexiconSet]?
    public struct Grammar: Codable {
        public var language: String
        public var bytes: Int
        public var maxLength: Int, minLength: Int
        public var collocation: Double, nonCollocation: Double, weakCollocation: Double, rear: Double
        public var homophones: Int
    }
    public var grammar: Grammar?
    public var outputs: [String: String]   // file → SHA-256
}

/// Characters that may sit inside a word without a syllable of their own:
/// the dots of transcribed names (李·卡斯利) and hyphens. In lexicon.tsv
/// such a character's place in the code is "-".
let marks: Set<Unicode.Scalar> = ["\u{00B7}", "\u{2027}", "\u{30FB}", "\u{FF65}", "\u{2022}",
                                  "-", "\u{2010}", "\u{2011}"]

/// The code for `text` read as `syllables` (toned), with "-" for each mark
/// character that has no syllable; nil if they cannot be lined up.
func alignedCode(_ text: String, _ syllables: [String]) -> String? {
    let scalars = Array(text.unicodeScalars)
    if scalars.count == syllables.count { return syllables.joined(separator: " ") }
    guard scalars.count > syllables.count,
          scalars.count - scalars.filter(marks.contains).count == syllables.count else { return nil }
    var parts: [String] = []
    var next = 0
    for s in scalars {
        if marks.contains(s) { parts.append("-") } else { parts.append(syllables[next]); next += 1 }
    }
    return parts.joined(separator: " ")
}

struct Entry {
    var set: Int        // 0 the core, k + 1 for options.sets[k]
    var text: String
    var code: String    // toned syllables, space-separated; "-" for a mark (see `marks`)
    var plain: String   // the same, without tones
    var weight: Double
    var source: String
}

private struct IssueLog {
    private var issues: [String: Report.Issue] = [:]
    private var order: [String] = []

    mutating func add(_ reason: String, dropped: Bool, _ file: String, _ row: DictFile.Row) {
        if issues[reason] == nil {
            issues[reason] = Report.Issue(reason: reason, dropped: dropped, count: 0, examples: [])
            order.append(reason)
        }
        issues[reason]!.count += 1
        if issues[reason]!.examples.count < 5 {
            let fields = [row.text, row.code ?? "", row.weight ?? ""].joined(separator: "⇥")
            issues[reason]!.examples.append("\(file):\(row.line): \(fields)")
        }
    }

    var all: [Report.Issue] { order.map { issues[$0]! } }
}

/// The drop list: one formula per line, `#` comments and blank lines skipped.
func loadDroppedRules(_ path: String) throws -> Set<String> {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        throw AlgebraError(description: "cannot read \(path)")
    }
    var dropped = Set<String>()
    for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
        var line = Substring(raw)
        if line.hasSuffix("\r") { line = line.dropLast() }
        if line.isEmpty || line.hasPrefix("#") { continue }
        dropped.insert(String(line))
    }
    return dropped
}

/// The scheme's own formulas, minus those on the drop list. A listed formula
/// this scheme has is recorded in `seen`. Fuzzy-group rules are not passed here.
func schemeFormulas(_ formulas: [String], dropping dropped: Set<String>, seen: inout Set<String>) -> [String] {
    var kept: [String] = []
    kept.reserveCapacity(formulas.count)
    for formula in formulas {
        if dropped.contains(formula) { seen.insert(formula) } else { kept.append(formula) }
    }
    return kept
}

/// Every listed rule must occur in some scheme. A 万象 update that rewrites one
/// then fails here instead of leaving the new spelling in.
func requireDroppedRulesPresent(_ dropped: Set<String>, seen: Set<String>) throws {
    let missing = dropped.subtracting(seen).sorted()
    guard !missing.isEmpty else { return }
    throw AlgebraError(description: "data/wanxiang-typo-rules.txt names a rule 万象's algebra no longer has: " +
        missing.joined(separator: ", ") + "; review the list")
}

/// Reads the manifest's tables, normalizes and validates every row, merges
/// duplicates, evaluates each spelling scheme, and writes the outputs.
public func prepare(_ options: PrepOptions) throws -> Report {
    let manifest = try DictFile(path: "\(options.source)/\(options.manifest)")
    guard let tables = manifest.header["import_tables"]?.strings, !tables.isEmpty else {
        throw AlgebraError(description: "\(options.manifest) imports no tables")
    }

    var entries: [Entry] = []
    var byKey: [String: Int] = [:]
    var syllableCache: [String: Syllable?] = [:]
    var sources: [Report.Source] = []
    var duplicates = 0

    // The core's dictionaries first, so a word any of them has stays in the
    // core; then each set's. A set keeps what the core lacks, and a word two
    // sets share is in both, so turning one off loses nothing the other has.
    var setOf: [String: Int] = [:]
    for (k, set) in options.sets.enumerated() { for table in set.tables { setOf["\(table).dict.yaml"] = k + 1 } }
    let tableFiles = tables.map { "\($0).dict.yaml" }
    let files = [options.manifest] + tableFiles.filter { setOf[$0] == nil } + tableFiles.filter { setOf[$0] != nil }
    for name in files {
        let set = setOf[name] ?? 0
        let file = name == options.manifest ? manifest : try DictFile(path: "\(options.source)/\(name)")
        var issues = IssueLog()
        var rows = 0, kept = 0, merged = 0
        file.forEachRow { row in
            rows += 1
            guard let code = row.code else { return issues.add("no code", dropped: true, name, row) }
            var syllables: [Syllable] = []
            for part in code.split(separator: " ", omittingEmptySubsequences: false) {
                let raw = String(part)
                if syllableCache[raw] == nil { syllableCache[raw] = Pinyin.syllable(raw) }
                guard let syllable = syllableCache[raw]! else {
                    return issues.add("not a pinyin syllable", dropped: true, name, row)
                }
                syllables.append(syllable)
            }
            let text = row.text.precomposedStringWithCanonicalMapping
            guard let tonedCode = alignedCode(text, syllables.map(\.toned)) else {
                return issues.add("text and code differ in length", dropped: true, name, row)
            }
            if text.unicodeScalars.count != syllables.count {
                issues.add("punctuation inside the word (· or -) is kept, with no syllable", dropped: false, name, row)
            }

            var weight = 0.0
            if let field = row.weight {
                switch Weight.read(field) {
                case .number(let value): weight = value
                case .prefix(let value):
                    weight = value
                    issues.add("weight has trailing characters; the number is used", dropped: false, name, row)
                case .scaled: issues.add("percentage weight with no preset vocabulary; 0 is used", dropped: false, name, row)
                case .notANumber: issues.add("weight is not a number; 0 is used", dropped: false, name, row)
                }
            } else {
                issues.add("no weight; 0 is used", dropped: false, name, row)
            }
            if weight < 0 {
                weight = 0
                issues.add("negative weight; 0 is used", dropped: false, name, row)
            }
            if row.extraColumns > 0 { issues.add("extra columns ignored", dropped: false, name, row) }

            let key = text + "\t" + tonedCode
            if let existing = byKey[key] ?? byKey["\(set)\t" + key] {
                duplicates += 1
                merged += 1
                entries[existing].weight = max(entries[existing].weight, weight)
                return
            }
            byKey[set == 0 ? key : "\(set)\t" + key] = entries.count
            entries.append(Entry(set: set, text: text, code: tonedCode,
                                 plain: syllables.map(\.plain).joined(separator: " "),
                                 weight: weight, source: name))
            kept += 1
        }
        if name != options.manifest || rows > 0 {
            sources.append(Report.Source(file: name, rows: rows, kept: kept, duplicates: merged, issues: issues.all))
        }
    }

    // The syllabary: every syllable some entry uses, as Rime builds it.
    var used = Set<String>()
    for entry in entries { for s in entry.code.split(separator: " ") where s != "-" { used.insert(String(s)) } }
    let syllabary = used.compactMap { syllableCache[$0] ?? nil }.sorted {
        ($0.plain, $0.tone, $0.toned) < ($1.plain, $1.tone, $1.toned)
    }

    try FileManager.default.createDirectory(atPath: options.output, withIntermediateDirectories: true)
    var outputs: [String: String] = [:]

    var text = "# toned\tplain\ttone\n"
    for s in syllabary { text += "\(s.toned)\t\(s.plain)\t\(s.tone)\n" }
    outputs["syllables.tsv"] = try write(text, to: options.output, "syllables.tsv")

    entries.sort { a, b in
        if !a.plain.utf8.elementsEqual(b.plain.utf8) { return a.plain.utf8.lexicographicallyPrecedes(b.plain.utf8) }
        if a.weight != b.weight { return a.weight > b.weight }
        if !a.text.utf8.elementsEqual(b.text.utf8) { return a.text.utf8.lexicographicallyPrecedes(b.text.utf8) }
        return a.code.utf8.lexicographicallyPrecedes(b.code.utf8)
    }
    var lexicons: [Report.LexiconSet] = []
    let described: [(id: String, name: String, on: Bool)] =
        [(id: "core", name: options.coreName, on: true)] + options.sets.map { (id: $0.id, name: $0.name, on: $0.on) }
    for (k, set) in described.enumerated() {
        let file = k == 0 ? "lexicon.tsv" : "lexicon.\(set.id).tsv"
        text = "#lexicon\t\(set.id)\t\(set.name)\t\(set.on ? "on" : "off")\n# text\tcode\tweight\tsource\n"
        text.reserveCapacity(k == 0 ? entries.count * 48 : 1 << 20)
        var count = 0
        for e in entries where e.set == k {
            text += "\(e.text)\t\(e.code)\t\(format(e.weight))\t\(e.source)\n"
            count += 1
        }
        outputs[file] = try write(text, to: options.output, file)
        lexicons.append(Report.LexiconSet(id: set.id, name: set.name, file: file, entries: count, on: set.on))
    }

    let algebraPath = "\(options.source)/\(options.algebra)"
    guard let algebraText = try? String(contentsOfFile: algebraPath, encoding: .utf8) else {
        throw AlgebraError(description: "cannot read \(algebraPath)")
    }
    let algebra: YAMLNode
    do { algebra = try YAML.parse(algebraText) } catch { throw AlgebraError(description: "\(options.algebra): \(error)") }

    var fuzzyRules: [Rule] = []
    for (bit, group) in options.fuzzy.enumerated() {
        guard let formulas = algebra.at(group.path + "/__append")?.strings ?? algebra.at(group.path)?.strings else {
            throw AlgebraError(description: "\(options.algebra) has no rule list at \(group.path)")
        }
        for formula in formulas {
            let rule = try Rule(formula)
            rule.fuzzyGroup = 1 << UInt32(bit)
            fuzzyRules.append(rule)
        }
    }
    // The drop list applies only to a scheme's own formulas. Fuzzy groups
    // stay whole: they are a separate feature (docs/fuzzy-pinyin.md).
    let dropped: Set<String>
    if let path = options.droppedRules { dropped = try loadDroppedRules(path) } else { dropped = [] }
    var seenDropped = Set<String>()
    var spellingReports: [Report.Spellings] = []
    for scheme in options.schemes {
        guard let formulas = algebra.at(scheme.path + "/__append")?.strings ?? algebra.at(scheme.path)?.strings else {
            throw AlgebraError(description: "\(options.algebra) has no rule list at \(scheme.path)")
        }
        let own = schemeFormulas(formulas, dropping: dropped, seen: &seenDropped)
        let rules = try fuzzyRules + own.map(Rule.init)
        let script = try project(syllables: syllabary.map(\.toned), rules: rules)
        var rows = 0
        var fuzzyRows = 0
        var byType: [String: Int] = [:]
        let title = scheme.path.split(separator: "/").last.map(String.init) ?? scheme.name
        text = "#scheme\t\(scheme.name)\t\(title)\t\(scheme.preedit)\n"
        text += "#fuzzy" + options.fuzzy.map { "\t" + $0.id }.joined() + "\n"
        text += "# spelling\tsyllable\ttype\tcredibility\tcorrection\tfuzzy groups (bits)\n"
        for spelling in script.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let origins = script[spelling]!
            let ordered = origins.keys.sorted {
                $0.syllable != $1.syllable ? $0.syllable.utf8.lexicographicallyPrecedes($1.syllable.utf8) : $0.fuzzy < $1.fuzzy
            }
            for origin in ordered {
                let p = origins[origin]!
                let credibility = p.credibility == 0 ? 0 : p.credibility    // no "-0.000000"
                text += "\(spelling)\t\(origin.syllable)\t\(p.type.name)\t\(String(format: "%.6f", credibility))\t" +
                    "\(p.isCorrection ? 1 : 0)\t\(origin.fuzzy)\n"
                rows += 1
                if origin.fuzzy != 0 { fuzzyRows += 1 }
                byType[p.type.name, default: 0] += 1
            }
        }
        let file = "spellings.\(scheme.name).tsv"
        outputs[file] = try write(text, to: options.output, file)
        spellingReports.append(Report.Spellings(scheme: scheme.path, file: file, rules: rules.count,
                                                spellings: script.count, rows: rows, rowsByType: byType,
                                                fuzzyRows: fuzzyRows,
                                                droppedRules: options.droppedRules == nil ? nil : formulas.count - own.count))
    }
    if options.droppedRules != nil {
        try requireDroppedRulesPresent(dropped, seen: seenDropped)
    }

    let aux = try AuxCodes(path: "\(options.source)/\(options.auxCodes)")
    outputs["aux.tsv"] = try write(aux.tsv(), to: options.output, "aux.tsv")

    let english = try EnglishWords(path: "\(options.source)/\(options.english)",
                                   inflections: try options.agid.map(EnglishInflections.init(path:)))
    outputs["english.tsv"] = try write(english.tsv(), to: options.output, "english.tsv")

    var charsetReport: Report.Charsets?
    if let unihan = options.unihan {
        let charsets = try Charsets(directory: unihan, extra: options.dailyExtra)
        outputs["charsets.tsv"] = try write(charsets.tsv(), to: options.output, "charsets.tsv")
        var used = Set<Unicode.Scalar>()
        for e in entries { for scalar in e.text.unicodeScalars { used.insert(scalar) } }
        charsetReport = charsets.report(used: used)
    }

    // The grammar model: its settings from the schema, beside the .gram file
    // they belong to, which must be the one the schema names.
    var grammarReport: Report.Grammar?
    if let gram = options.grammar {
        guard let data = FileManager.default.contents(atPath: "\(options.source)/\(options.schema)") else {
            throw AlgebraError(description: "cannot read \(options.schema)")
        }
        let (language, settings, homophones) = try GrammarModel.schema(String(decoding: data, as: UTF8.self))
        let name = URL(fileURLWithPath: gram).deletingPathExtension().lastPathComponent
        guard name == language else {
            throw AlgebraError(description: "the schema's grammar is \(language), but the model given is \(gram)")
        }
        let size = try GrammarModel.check(gram)
        outputs["grammar.tsv"] = try write(GrammarModel.settingsTSV(language: language, settings: settings,
                                                                    homophones: homophones, fileSize: size),
                                           to: options.output, "grammar.tsv")
        grammarReport = Report.Grammar(language: language, bytes: size, maxLength: settings.maxLength,
                                       minLength: settings.minLength, collocation: settings.collocationPenalty,
                                       nonCollocation: settings.nonCollocationPenalty,
                                       weakCollocation: settings.weakCollocationPenalty, rear: settings.rearPenalty,
                                       homophones: homophones)
    }

    var report = Report(upstream: try upstream(options.lock), sources: sources, duplicatesMerged: duplicates,
                        entries: entries.count, syllables: syllabary.count,
                        plainSyllables: Set(syllabary.map(\.plain)).count,
                        spellings: spellingReports, aux: aux.report, charsets: charsetReport,
                        lexicons: lexicons, outputs: outputs)
    report.grammar = grammarReport
    report.english = english.report(file: options.english)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(report).write(to: URL(fileURLWithPath: "\(options.output)/report.json"), options: .atomic)
    return report
}

/// A weight as librime keeps it: integral weights print as integers.
private func format(_ weight: Double) -> String {
    weight == weight.rounded() && abs(weight) < 9e15 ? String(Int64(weight)) : String(weight)
}

/// Writes atomically and returns the file's SHA-256.
private func write(_ text: String, to directory: String, _ name: String) throws -> String {
    let data = Data(text.utf8)
    try data.write(to: URL(fileURLWithPath: "\(directory)/\(name)"), options: .atomic)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func upstream(_ lockPath: String?) throws -> Report.Upstream {
    var result = Report.Upstream()
    guard let lockPath else { return result }
    guard let lock = try? String(contentsOfFile: lockPath, encoding: .utf8) else {
        throw AlgebraError(description: "cannot read \(lockPath)")
    }
    for line in lock.split(separator: "\n") where !line.hasPrefix("#") {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { continue }
        switch parts[0] {
        case "repo": result.repo = parts[1]
        case "tag": result.tag = parts[1]
        case "commit": result.commit = parts[1]
        default: break
        }
    }
    return result
}
