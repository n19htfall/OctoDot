/// What changed between two import reports, for reviewing an upstream bump:
/// one line per number that moved, and nothing for those that did not.
public func compare(_ old: Report, _ new: Report) -> [String] {
    var lines: [String] = []
    func delta(_ label: String, _ a: Int, _ b: Int) {
        guard a != b else { return }
        lines.append("  \(label): \(a) → \(b) (\(b > a ? "+" : "")\(b - a))")
    }

    if old.upstream.tag != new.upstream.tag || old.upstream.commit != new.upstream.commit {
        lines.append("  upstream: \(old.upstream.tag ?? "?") → \(new.upstream.tag ?? "?")")
    }
    delta("entries", old.entries, new.entries)
    delta("duplicates merged", old.duplicatesMerged, new.duplicatesMerged)
    delta("syllables", old.syllables, new.syllables)
    delta("syllables without tones", old.plainSyllables, new.plainSyllables)

    let oldSources = Dictionary(old.sources.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
    for source in new.sources {
        guard let before = oldSources[source.file] else {
            lines.append("  \(source.file): new, \(source.kept) entries kept")
            continue
        }
        delta("\(source.file) rows", before.rows, source.rows)
        delta("\(source.file) kept", before.kept, source.kept)
        let beforeIssues = Dictionary(before.issues.map { ($0.reason, $0.count) }, uniquingKeysWith: +)
        let afterIssues = Dictionary(source.issues.map { ($0.reason, $0.count) }, uniquingKeysWith: +)
        for reason in Set(beforeIssues.keys).union(afterIssues.keys).sorted() {
            delta("\(source.file) \"\(reason)\"", beforeIssues[reason] ?? 0, afterIssues[reason] ?? 0)
        }
    }
    for file in oldSources.keys.sorted() where !new.sources.contains(where: { $0.file == file }) {
        lines.append("  \(file): no longer imported")
    }

    let oldSpellings = Dictionary(old.spellings.map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
    for scheme in new.spellings {
        guard let before = oldSpellings[scheme.file] else { continue }
        delta("\(scheme.file) rules", before.rules, scheme.rules)
        delta("\(scheme.file) spellings", before.spellings, scheme.spellings)
        delta("\(scheme.file) rows", before.rows, scheme.rows)
    }
    if let a = old.lexicons, let b = new.lexicons {
        let before = Dictionary(a.map { ($0.id, $0.entries) }, uniquingKeysWith: { x, _ in x })
        for set in b { delta("lexicon \(set.id) entries", before[set.id] ?? 0, set.entries) }
    }
    if let a = old.charsets, let b = new.charsets {
        if a.unicode != b.unicode { lines.append("  Unicode: \(a.unicode) → \(b.unicode)") }
        for name in Set(a.lexiconCharactersBySet.keys).union(b.lexiconCharactersBySet.keys).sorted() {
            delta("lexicon characters in \(name)", a.lexiconCharactersBySet[name] ?? 0, b.lexiconCharactersBySet[name] ?? 0)
        }
        delta("lexicon characters in no set", a.lexiconCharactersInNoSet, b.lexiconCharactersInNoSet)
    }
    if let a = old.aux, let b = new.aux {
        delta("aux characters", a.characters, b.characters)
        for scheme in Set(a.charactersByScheme.keys).union(b.charactersByScheme.keys).sorted() {
            delta("aux \(scheme) characters", a.charactersByScheme[scheme] ?? 0, b.charactersByScheme[scheme] ?? 0)
        }
    }
    return lines
}
