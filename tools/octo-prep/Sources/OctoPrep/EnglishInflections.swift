import Foundation

/// Which English words are inflections of others, from AGID's infl.txt
/// (SCOWL's Automatically Generated Inflection Database): plural nouns and
/// verbs' third-person -s forms, which OctoDot leaves out of its English
/// candidates ("changes", "cars": the lemma is what one types the word for).
///
/// infl.txt lines: "<word> <pos>: <forms>", forms in groups split by " | ",
/// alternatives in a group by ", ", each "<form><tags>[ <level>][ {<sense>}]".
/// For N every form is a plural. For V the groups are past | [past
/// participle] | -ing | -s, so the -s form is the last; "be" is special, and
/// its third person is "is". Entries whose part of speech AGID was unsure of
/// ("car V?") and forms tagged ~ ("a slight chance" of being an inflection)
/// are ignored.
struct EnglishInflections {
    private(set) var bases: [String: Set<String>] = [:]     // inflected form → the words it inflects
    private(set) var headwords: Set<String> = []           // words AGID lists as lemmas, part of speech known

    /// Words AGID files as inflections that are words of their own: "its"
    /// (the plural of the noun "it", there).
    static let keep: Set<String> = ["its"]

    init(path: String) throws {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw AlgebraError(description: "cannot read \(path)")
        }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let head = line[..<colon].split(separator: " ")
            guard head.count == 2 else { continue }
            let word = head[0].lowercased(), pos = head[1]
            // A lemma only where AGID knew its part of speech: "cars N?" is one
            // it made up from the word list, not a word of its own.
            guard !pos.hasSuffix("?") else { continue }
            headwords.insert(word)
            guard pos == "N" || pos == "V" else { continue }
            let groups = line[line.index(after: colon)...].split(separator: "|")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let chosen: [String] = pos == "N" ? groups : word == "be" ? ["is"] : groups.last.map { [$0] } ?? []
            for group in chosen {
                for alternative in group.split(separator: ",") {
                    guard let token = alternative.split(separator: " ").first else { continue }
                    var form = String(token)
                    var tags = ""
                    while let last = form.last, "~<!?".contains(last) {
                        tags.append(last)
                        form.removeLast()
                    }
                    form = form.lowercased()
                    if tags.contains("~") || form.isEmpty || form == word { continue }
                    bases[form, default: []].insert(word)
                }
            }
        }
    }

    /// Whether `form` (one lowercase word, with `weight` in the dictionary)
    /// is an inflection to leave out: AGID lists it as one, it is no lemma
    /// itself (news, series, his stay), and its base is in real use, with at
    /// least a quarter of its weight. A form that outgrew a rare base is a
    /// word of its own: data (datum), physics (physic).
    func isInflection(_ form: String, weight: Int, weightOf: (String) -> Int) -> Bool {
        guard !Self.keep.contains(form), !headwords.contains(form), let of = bases[form] else { return false }
        return of.contains { weightOf($0) * 4 >= weight }
    }
}
