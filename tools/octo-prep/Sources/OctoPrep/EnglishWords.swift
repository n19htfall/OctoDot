import Foundation

/// 万象's English dictionary (dicts/en.dict.yaml): words and terms with their
/// weights, offered as candidates beside the Chinese (docs/english-design.md).
///
/// Normalized to what can be typed: a code of lowercase letters a-z, with
/// spaces, apostrophes, hyphens and dots dropped ("GitHub Copilot" is
/// githubcopilot, "'tis" is tis). An entry whose code has anything else, a
/// digit for one, is left out: digits pick candidates. Forms of one code
/// ("in", "In", "IN") are kept together, most used first, except that the
/// all-lowercase form comes first whenever it has a quarter of the top
/// form's weight: typing "in" means "in", though 万象 weighs "IN" a little
/// higher. A code with no lowercase form keeps its own ("iPhone", "NASA").
///
/// Plural nouns and third-person -s verbs are left out ("changes", "cars",
/// "is"), as AGID identifies them (EnglishInflections): one types a word
/// for its lemma. Only lowercase forms: a capitalized one is a name
/// ("Windows" stays, "windows" goes). A lowercase phrase goes if its last
/// word would ("best practices"). A code left with no form goes.
///
/// english.tsv, one line per code, codes ascending:
///   code \t weight (its forms' summed) \t form \t form ...
struct EnglishWords {
    static let maxCode = 32         // keys: the IME's input holds 64
    static let maxForms = 4

    private(set) var forms: [String: [String: Int]] = [:]   // code → form → weight
    private(set) var rows = 0
    private(set) var skipped: [String: Int] = [:]           // reason → rows
    let inflections: EnglishInflections?

    init(path: String, inflections: EnglishInflections? = nil) throws {
        self.inflections = inflections
        let dict = try DictFile(path: path)
        dict.forEachRow { row in
            rows += 1
            let text = row.text
            guard !text.isEmpty, !text.contains("\t"), !text.contains("\n") else {
                skipped["unusable text", default: 0] += 1
                return
            }
            guard let code = Self.code(of: row.code ?? text) else {
                skipped["code not letters a-z", default: 0] += 1
                return
            }
            let weight = max(1, Int(row.weight ?? "1") ?? 1)
            forms[code, default: [:]][text, default: 0] += weight
        }
    }

    /// The letters a user types for `raw`, or nil if it holds anything else.
    static func code(of raw: String) -> String? {
        var code = ""
        for scalar in raw.unicodeScalars {
            switch scalar {
            case "a"..."z": code.unicodeScalars.append(scalar)
            case "A"..."Z": code.unicodeScalars.append(Unicode.Scalar(scalar.value + 32)!)
            case " ", "'", "-", ".", "’": continue
            default: return nil
            }
        }
        return code.isEmpty || code.count > maxCode ? nil : code
    }

    /// The forms of `code` that stay: none is an inflection to leave out.
    func kept(_ code: String) -> [String: Int] {
        guard let inflections else { return forms[code]! }
        let weightOf = { (word: String) in forms[word]?.values.reduce(0, +) ?? 0 }
        return forms[code]!.filter { form, weight in
            guard form == form.lowercased() else { return true }
            let words = form.split(separator: " ")
            guard let last = words.last.map(String.init) else { return true }
            if words.count == 1 { return !inflections.isInflection(last, weight: weight, weightOf: weightOf) }
            let lastWeight = weightOf(last)
            return lastWeight == 0 || !inflections.isInflection(last, weight: lastWeight, weightOf: weightOf)
        }
    }

    /// How many forms and codes the inflection filter leaves out.
    func inflectionCounts() -> (forms: Int, codes: Int) {
        var dropped = 0, gone = 0
        for code in forms.keys {
            let left = kept(code).count
            dropped += forms[code]!.count - left
            if left == 0 { gone += 1 }
        }
        return (dropped, gone)
    }

    func tsv() -> String {
        var out = "# code\tweight\tforms, most used first\n"
        for code in forms.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let byForm = kept(code)
            if byForm.isEmpty { continue }
            var ranked = byForm.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            if let plain = ranked.firstIndex(where: { $0.key == code }), plain > 0,
               ranked[plain].value * 4 >= ranked[0].value {
                ranked.insert(ranked.remove(at: plain), at: 0)
            }
            let total = ranked.reduce(0) { $0 + $1.value }
            out += "\(code)\t\(total)\t" + ranked.prefix(Self.maxForms).map(\.key).joined(separator: "\t") + "\n"
        }
        return out
    }

    func report(file: String) -> Report.English {
        let (dropped, gone) = inflectionCounts()
        var reasons = skipped
        if dropped > 0 { reasons["inflected: plural noun or third-person -s (forms)"] = dropped }
        return Report.English(file: file, rows: rows, codes: forms.count - gone,
                              forms: forms.values.reduce(0) { $0 + $1.count } - dropped, skipped: reasons)
    }
}
