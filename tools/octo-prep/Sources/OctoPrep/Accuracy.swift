import Foundation

/// The accuracy set (make accuracy, make test), built from the outside
/// sources pinned in data/accuracy.lock, so no line of it is picked by hand:
///
///   common      words234 (rime-schema-compare): 450 frequent words of
///               Zhihu text, with readings audited by hand
///   names, places, idioms
///               THUOCL's most used, `perCategory` of each, taking only
///               what phrase-pinyin-data lists as a word (THUOCL's places
///               hold segmentation fragments such as 新一), read as it
///               reads them
///   sentences   zhihu120 (rime-schema-compare): 120 sentences of Zhihu
///               text, readings audited, which its reports also type
///               through librime
///
/// Each reading must be one 万象 gives that character in some word, or the
/// IME could not type it, and a word 万象 reads otherwise is set aside
/// rather than guessed at. What is set aside, and why, goes to review.tsv.
public enum AccuracySet {
    public struct Line: Equatable, Sendable {
        public var category: String
        public var text: String
        public var syllables: [String]
    }

    public struct Result: Sendable {
        public var words: [Line] = []
        public var sentences: [Line] = []
        public var review: [(category: String, text: String, reason: String)] = []
    }

    /// What 万象 reads each character as, in any word, and how it reads
    /// whole words (only those asked for).
    public struct Readings: Sendable {
        public var plain: Set<String> = []
        public var chars: [Unicode.Scalar: Set<String>] = [:]
        public var words: [String: Set<[String]>] = [:]
        public var usual: [Unicode.Scalar: (reading: String, weight: Double)] = [:]   // each character's most used reading alone
    }

    public static let categories = [("names", "THUOCL_lishimingren.txt"), ("places", "THUOCL_diming.txt"),
                                    ("idioms", "THUOCL_chengyu.txt")]

    // MARK: Reading the sources

    /// syllables.tsv: toned syllable → toneless.
    public static func syllables(_ tsv: String) -> [String: String] {
        var map: [String: String] = [:]
        for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
            let f = line.split(separator: "\t")
            if f.count >= 2 { map[String(f[0])] = String(f[1]) }
        }
        return map
    }

    /// Adds a prepared lexicon (text, toned code, ...) to `r`: every
    /// character's readings, and the readings of the words in `wanted`.
    public static func addLexicon(_ data: Data, toned: [String: String], wanted: Set<String>, to r: inout Readings) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count && bytes[end] != 0x0A { end += 1 }
                defer { start = end + 1 }
                guard end > start, bytes[start] != 0x23 else { continue }       // '#'
                var tab1 = start
                while tab1 < end && bytes[tab1] != 0x09 { tab1 += 1 }
                var tab2 = tab1 + 1
                while tab2 < end && bytes[tab2] != 0x09 { tab2 += 1 }
                guard tab1 < end, tab2 <= end else { continue }
                let text = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<tab1]), as: UTF8.self)
                let code = String(decoding: UnsafeBufferPointer(rebasing: bytes[(tab1 + 1)..<tab2]), as: UTF8.self)
                var tab3 = tab2 + 1
                while tab3 < end && bytes[tab3] != 0x09 { tab3 += 1 }
                let weight = tab2 + 1 < end
                    ? Double(String(decoding: UnsafeBufferPointer(rebasing: bytes[(tab2 + 1)..<tab3]), as: UTF8.self)) ?? 0
                    : 0
                let scalars = Array(text.unicodeScalars)
                let syls = code.split(separator: " ").map { toned[String($0)] ?? "" }
                guard scalars.count == syls.count, !syls.contains("") else { continue }  // words with marks
                for (c, s) in zip(scalars, syls) { r.chars[c, default: []].insert(s) }
                if wanted.contains(text) { r.words[text, default: []].insert(syls) }
                if scalars.count == 1, weight > (r.usual[scalars[0]]?.weight ?? -1) { r.usual[scalars[0]] = (syls[0], weight) }
            }
        }
    }

    /// A THUOCL file: words in order of how many documents use them. Tab
    /// separated, padded with spaces in places, with CR or LF line ends and
    /// sometimes a byte-order mark.
    public static func thuocl(_ text: String) -> [String] {
        var entries: [(String, Int)] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }) {
            let f = line.split(separator: "\t")
            guard f.count >= 2 else { continue }
            let word = f[0].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
            let df = Int(f[1].trimmingCharacters(in: .whitespaces)) ?? 0
            if !word.isEmpty { entries.append((word, df)) }
        }
        return entries.enumerated().sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
            .map { $0.element.0 }
    }

    /// phrase-pinyin-data: "词: cí yǔ" → each word's readings, toneless.
    /// A reading with a syllable the syllabary lacks comes back empty.
    public static func phrasePinyin(_ text: String, plain: Set<String>) -> [String: [[String]]] {
        var map: [String: [[String]]] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let word = String(line[..<colon])
            let syls = line[line.index(after: colon)...].split(separator: " ").map { s -> String in
                guard let p = Pinyin.syllable(String(s))?.plain, plain.contains(p) else { return "" }
                return p
            }
            map[word, default: []].append(syls.contains("") ? [] : syls)
        }
        return map
    }

    // MARK: Building

    /// Splits pinyin written without spaces ("keneng") into one syllable per
    /// character of `text`, each a reading 万象 has for it (ke neng, not
    /// ken eng). Nil if there is no such split.
    public static func split(_ text: String, _ joined: String, _ r: Readings) -> [String]? {
        let chars = Array(text.unicodeScalars)
        let letters = Array(joined.lowercased().replacingOccurrences(of: "ü", with: "v").utf8)
        var failed = Set<Int>()                      // (position, character) known to lead nowhere
        func go(_ i: Int, _ k: Int) -> [String]? {
            if i == letters.count { return k == chars.count ? [] : nil }
            if k == chars.count || failed.contains(i * 1024 + k) { return nil }
            for len in stride(from: min(6, letters.count - i), through: 1, by: -1) {
                let s = String(decoding: letters[i..<(i + len)], as: UTF8.self)
                guard r.plain.contains(s), r.chars[chars[k]]?.contains(s) == true else { continue }
                if let rest = go(i + len, k + 1) { return [s] + rest }
            }
            failed.insert(i * 1024 + k)
            return nil
        }
        return chars.count < 1024 ? go(0, 0) : nil
    }

    /// The pinyin column: syllables split by spaces, and by ' where two of
    /// them together spell one syllable (xi'an), as a typist types it.
    public static func pinyinField(_ syllables: [String], plain: Set<String>) -> String {
        guard var out = syllables.first else { return "" }
        for (a, b) in zip(syllables, syllables.dropFirst()) {
            out += (plain.contains(a + b) ? "'" : " ") + b
        }
        return out
    }

    /// rime-schema-compare's sentences from its corpus (text_pipeline.py):
    /// each line split at ，, 。 , and a . that is not a decimal point, and at
    /// curly quotes; pieces with 、 or 《》 dropped; then only pieces of at
    /// least 5 characters that are all CJK ideographs (U+4E00-U+9FFF) kept.
    public static func corpusSentences(_ text: String) -> [String] {
        var out: [String] = []
        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = Array(raw.unicodeScalars)
            var piece: [Unicode.Scalar] = []
            func emit() {
                let s = String(String.UnicodeScalarView(piece)).trimmingCharacters(in: .whitespaces)
                piece.removeAll()
                guard !s.contains("、") && !s.contains("《") && !s.contains("》") else { return }
                let scalars = s.unicodeScalars
                if scalars.count >= 5 && scalars.allSatisfy({ (0x4E00...0x9FFF).contains($0.value) }) { out.append(s) }
            }
            for (i, c) in line.enumerated() {
                let decimal = c == "." && i > 0 && i + 1 < line.count &&
                    ("0"..."9").contains(line[i - 1]) && ("0"..."9").contains(line[i + 1])
                if c == "，" || c == "," || c == "。" || c == "\u{201C}" || c == "\u{201D}" || (c == "." && !decimal) {
                    emit()
                } else {
                    piece.append(c)
                }
            }
            emit()
        }
        return out
    }

    /// Readings for a sentence without any, as pypinyin's lazy_pinyin finds
    /// them, which rime-schema-compare types: the longest phrase-pinyin-data
    /// word at each place (up to 8 characters), else the character's most
    /// used reading in 万象. A reading 万象 does not have for a character
    /// falls back to that. Nil if some character has no reading at all.
    public static func readSentence(_ text: String, ppd: [String: [[String]]], _ r: Readings) -> [String]? {
        let chars = Array(text.unicodeScalars)
        var out: [String] = []
        var i = 0
        while i < chars.count {
            var taken = false
            for len in stride(from: min(8, chars.count - i), through: 2, by: -1) {
                let word = String(String.UnicodeScalarView(chars[i..<(i + len)]))
                if let listed = ppd[word], let reading = listed.first(where: { $0.count == len }) {
                    for (k, s) in reading.enumerated() {
                        let c = chars[i + k]
                        if r.chars[c]?.contains(s) == true { out.append(s) }
                        else if let u = r.usual[c]?.reading { out.append(u) }
                        else { return nil }
                    }
                    i += len
                    taken = true
                    break
                }
            }
            if !taken {
                guard let u = r.usual[chars[i]]?.reading else { return nil }
                out.append(u)
                i += 1
            }
        }
        return out
    }

    static func isHan(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    /// Builds the set from the sources' contents.
    public static func build(goldWords: String, goldSentences: String, corpus: String = "",
                             thuocl: [(category: String, text: String)],
                             phrasePinyin ppd: [String: [[String]]], readings r: Readings,
                             perCategory: Int) -> Result {
        var result = Result()
        var seen = Set<String>()
        func gold(_ tsv: String, _ category: String) -> [Line] {
            var lines: [Line] = []
            for line in tsv.split(separator: "\n") where !line.hasPrefix("#") {
                let f = line.split(separator: "\t")
                guard f.count >= 2 else { continue }
                let text = String(f[0]), joined = String(f[1])
                if let syls = split(text, joined, r) {
                    lines.append(Line(category: category, text: text, syllables: syls))
                    seen.insert(text)
                } else {
                    result.review.append((category, text, "its reading \(joined) does not split into readings 万象 has"))
                }
            }
            return lines
        }
        result.words = gold(goldWords, "common")
        result.sentences = gold(goldSentences, "zhihu120")
        // The benchmark's full corpus, less the sentences zhihu120 holds with
        // audited readings: where decisions are measured, so that zhihu120
        // stays a held-out check.
        let held = Set(result.sentences.map(\.text))
        for sentence in corpusSentences(corpus) where !held.contains(sentence) {
            if let syls = readSentence(sentence, ppd: ppd, r) {
                result.sentences.append(Line(category: "hotlist", text: sentence, syllables: syls))
            } else {
                result.review.append(("hotlist", sentence, "a character with no reading in 万象"))
            }
        }

        for (category, text) in thuocl {
            var taken = 0
            for word in Self.thuocl(text) where taken < perCategory {
                let n = word.unicodeScalars.count
                guard n >= 2 && n <= 8 && isHan(word) && !seen.contains(word) else { continue }
                seen.insert(word)
                guard let listed = ppd[word] else {
                    result.review.append((category, word, "not a word in phrase-pinyin-data"))
                    continue
                }
                let options = listed.filter { $0.count == n }
                guard !options.isEmpty else {
                    result.review.append((category, word, "phrase-pinyin-data's reading has a syllable 万象 lacks"))
                    continue
                }
                var chosen: [String]
                if let own = r.words[word], !own.isEmpty {
                    guard let agreed = options.first(where: { own.contains($0) }) else {
                        let theirs = options.map { $0.joined(separator: " ") }.joined(separator: " / ")
                        let ours = own.map { $0.joined(separator: " ") }.sorted().joined(separator: " / ")
                        result.review.append((category, word, "phrase-pinyin-data reads \(theirs), 万象 \(ours)"))
                        continue
                    }
                    chosen = agreed
                } else {
                    guard Set(options).count == 1 else {
                        result.review.append((category, word, "several readings, and not in 万象 to choose"))
                        continue
                    }
                    chosen = options[0]
                }
                let scalars = Array(word.unicodeScalars)
                if let k = scalars.indices.first(where: { r.chars[scalars[$0]]?.contains(chosen[$0]) != true }) {
                    result.review.append((category, word, "万象 never reads \(Character(scalars[k])) as \(chosen[k])"))
                    continue
                }
                result.words.append(Line(category: category, text: word, syllables: chosen))
                taken += 1
            }
        }
        return result
    }

    // MARK: Files

    /// Reads the sources from `sources` (.data/accuracy) and the prepared
    /// lexicons from `prepared`, builds the set and writes words.tsv,
    /// sentences.tsv and review.tsv into `out`.
    public static func make(sources: String, prepared: String, out: String, perCategory: Int) throws -> Result {
        func read(_ path: String) throws -> String {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw AlgebraError(description: "cannot read \(path)")
            }
            return String(decoding: data, as: UTF8.self)
        }
        let src = URL(fileURLWithPath: sources)
        let toned = syllables(try read("\(prepared)/syllables.tsv"))
        var r = Readings()
        r.plain = Set(toned.values)
        let thuoclTexts = try categories.map { (category: $0.0, text: try read(src.appendingPathComponent("thuocl/\($0.1)").path)) }
        var wanted = Set<String>()
        for t in thuoclTexts { wanted.formUnion(thuocl(t.text)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: prepared)
            .filter { $0.hasPrefix("lexicon") && $0.hasSuffix(".tsv") }.sorted()
        for name in names {
            guard let data = FileManager.default.contents(atPath: "\(prepared)/\(name)") else {
                throw AlgebraError(description: "cannot read \(prepared)/\(name)")
            }
            addLexicon(data, toned: toned, wanted: wanted, to: &r)
        }
        let ppd = phrasePinyin(try read(src.appendingPathComponent("phrase-pinyin-data/large_pinyin.txt").path),
                               plain: r.plain)
        let result = build(goldWords: try read(src.appendingPathComponent("rime-schema-compare/words234.pin.tsv").path),
                           goldSentences: try read(src.appendingPathComponent("rime-schema-compare/zhihu120.pin.tsv").path),
                           corpus: try read(src.appendingPathComponent("rime-schema-compare/zhihu_hotlist_2026-08-30.txt").path),
                           thuocl: thuoclTexts, phrasePinyin: ppd, readings: r, perCategory: perCategory)
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        try tsv(result.words, header: wordsHeader(perCategory), plain: r.plain)
            .write(toFile: "\(out)/words.tsv", atomically: true, encoding: .utf8)
        try tsv(result.sentences, header: sentencesHeader, plain: r.plain)
            .write(toFile: "\(out)/sentences.tsv", atomically: true, encoding: .utf8)
        var review = "# Set aside while building the accuracy set, and why (octo-prep accuracy).\n# category\ttext\treason\n"
        for item in result.review { review += "\(item.category)\t\(item.text)\t\(item.reason)\n" }
        try review.write(toFile: "\(out)/review.tsv", atomically: true, encoding: .utf8)
        return result
    }

    /// Readings for many sentences, as the corpus sentences get theirs, for
    /// other tools: each line of `input` (CJK characters only)
    /// becomes "text \t syllables" in `output`; a line with a character that
    /// has no reading is left out. Returns (read, left out).
    public static func readLines(sources: String, prepared: String, input: String, output: String) throws -> (Int, Int) {
        guard let toneData = FileManager.default.contents(atPath: "\(prepared)/syllables.tsv"),
              let ppdData = FileManager.default.contents(atPath: "\(sources)/phrase-pinyin-data/large_pinyin.txt") else {
            throw AlgebraError(description: "cannot read syllables.tsv or phrase-pinyin-data")
        }
        let toned = syllables(String(decoding: toneData, as: UTF8.self))
        var r = Readings()
        r.plain = Set(toned.values)
        let names = try FileManager.default.contentsOfDirectory(atPath: prepared)
            .filter { $0.hasPrefix("lexicon") && $0.hasSuffix(".tsv") }.sorted()
        for name in names {
            guard let data = FileManager.default.contents(atPath: "\(prepared)/\(name)") else { continue }
            addLexicon(data, toned: toned, wanted: [], to: &r)
        }
        let ppd = phrasePinyin(String(decoding: ppdData, as: UTF8.self), plain: r.plain)
        guard let reader = FileHandle(forReadingAtPath: input) else { throw AlgebraError(description: "cannot read \(input)") }
        FileManager.default.createFile(atPath: output, contents: nil)
        guard let writer = FileHandle(forWritingAtPath: output) else { throw AlgebraError(description: "cannot write \(output)") }
        var read = 0, left = 0
        var pending = Data()
        var out = ""
        func flush() {
            writer.write(Data(out.utf8))
            out.removeAll(keepingCapacity: true)
        }
        func handle(_ line: Substring) {
            guard !line.isEmpty else { return }
            if let syls = readSentence(String(line), ppd: ppd, r) {
                out += "\(line)\t\(syls.joined(separator: " "))\n"
                read += 1
                if out.utf8.count > 1 << 20 { flush() }
            } else {
                left += 1
            }
        }
        while true {
            let chunk = reader.readData(ofLength: 1 << 22)
            if chunk.isEmpty { break }
            pending.append(chunk)
            if let last = pending.lastIndex(of: 0x0A) {
                let text = String(decoding: pending[pending.startIndex..<last], as: UTF8.self)
                for line in text.split(separator: "\n") { handle(line) }
                pending = Data(pending[(last + 1)...])
            }
        }
        if !pending.isEmpty { handle(Substring(String(decoding: pending, as: UTF8.self))) }
        flush()
        try writer.close()
        return (read, left)
    }

    static func tsv(_ lines: [Line], header: String, plain: Set<String>) -> String {
        var out = header
        var category = ""
        for l in lines {
            if l.category != category {
                out += "\n## \(l.category)\n"
                category = l.category
            }
            out += "\(l.text)\t\(pinyinField(l.syllables, plain: plain))\n"
        }
        return out
    }

    static func wordsHeader(_ n: Int) -> String {
        """
        # The accuracy set's words, typed alone (make accuracy). Built by
        # octo-prep accuracy from data/accuracy.lock's sources; not edited.
        #   common   words234 (rime-schema-compare): frequent words of Zhihu
        #            text, readings audited by hand
        #   names, places, idioms
        #            THUOCL's \(n) most used of each that phrase-pinyin-data
        #            lists as a word, read as it reads them
        # What was set aside, and why, is in review.tsv.

        """
    }

    static let sentencesHeader = """
        # The accuracy set's sentences, each typed whole (make accuracy), from
        # rime-schema-compare, whose reports type the same through librime:
        #   zhihu120  120 sentences of Zhihu text with readings audited by hand:
        #             a held-out check
        #   hotlist   the rest of its corpus (zhihu_hotlist_2026-08-30), split
        #             as it splits it, read as pypinyin reads it: where
        #             decisions are measured
        # Built by octo-prep accuracy from data/accuracy.lock's sources.

        """
}
