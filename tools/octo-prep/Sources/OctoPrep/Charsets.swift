import Foundation

/// The character sets a character belongs to, from Unicode's Unihan
/// database (UAX #38):
///   han     an ideograph: Unihan gives it a radical and stroke count (kRSUnicode)
///   tgh     通用规范汉字表 (2013), the 8,105 characters of standard modern use (kTGH)
///   gb2312  GB 2312-80, the 6,763 hanzi of the old national encoding (kGB0)
///   big5    Big5, the traditional characters of Taiwan and Hong Kong (kBigFive)
///   extra   OctoDot's own additions to the daily set (data/daily-extra.txt)
struct Charsets {
    static let fields: [(field: String, name: String, file: String)] = [
        ("kRSUnicode", "han", "Unihan_IRGSources.txt"),
        ("kTGH", "tgh", "Unihan_OtherMappings.txt"),
        ("kGB0", "gb2312", "Unihan_OtherMappings.txt"),
        ("kBigFive", "big5", "Unihan_OtherMappings.txt"),
    ]

    static let extra: UInt8 = 1 << 4

    var sets: [Unicode.Scalar: UInt8] = [:]     // bit i: fields[i]; then extra
    var version = ""

    init(directory: String, extra extraPath: String? = nil) throws {
        var files: [String: [Int]] = [:]
        for (i, f) in Charsets.fields.enumerated() { files[f.file, default: []].append(i) }
        for (file, indices) in files.sorted(by: { $0.key < $1.key }) {
            let path = "\(directory)/\(file)"
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                throw AlgebraError(description: "cannot read \(path)")
            }
            for line in text.split(separator: "\n") {
                if line.hasPrefix("# Unicode Version ") { version = String(line.dropFirst(18)) }
                guard line.hasPrefix("U+") else { continue }
                let parts = line.split(separator: "\t", maxSplits: 2)
                guard parts.count == 3, let i = indices.first(where: { Charsets.fields[$0].field == parts[1] }) else {
                    continue
                }
                guard let value = UInt32(parts[0].dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) else {
                    throw AlgebraError(description: "\(file): bad code point in \"\(line)\"")
                }
                sets[scalar, default: 0] |= 1 << UInt8(i)
            }
        }
        for (i, f) in Charsets.fields.enumerated() where !sets.values.contains(where: { $0 & (1 << UInt8(i)) != 0 }) {
            throw AlgebraError(description: "\(directory): no \(f.field) entries")
        }
        guard let extraPath else { return }
        guard let text = try? String(contentsOfFile: extraPath, encoding: .utf8) else {
            throw AlgebraError(description: "cannot read \(extraPath)")
        }
        for (n, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if line.isEmpty || line.hasPrefix("#") { continue }
            let character = line.split(separator: "\t", maxSplits: 1)[0].precomposedStringWithCanonicalMapping
            guard character.unicodeScalars.count == 1, let scalar = character.unicodeScalars.first,
                  let bits = sets[scalar], bits & 1 != 0 else {
                throw AlgebraError(description: "\(extraPath):\(n + 1): expected one ideograph, then a tab and a note")
            }
            if bits & 2 != 0 {
                throw AlgebraError(description: "\(extraPath):\(n + 1): \(character) is already in 通用规范汉字表")
            }
            sets[scalar] = bits | Charsets.extra
        }
    }

    func names(_ bits: UInt8) -> [String] {
        var out = Charsets.fields.indices.filter { bits & (1 << UInt8($0)) != 0 }.map { Charsets.fields[$0].name }
        if bits & Charsets.extra != 0 { out.append("extra") }
        return out
    }

    /// One line per character in code point order: the character, then the
    /// names of its sets, space-separated.
    func tsv() -> String {
        var text = "# char\tsets\n"
        text.reserveCapacity(sets.count * 24)
        for scalar in sets.keys.sorted(by: { $0.value < $1.value }) {
            text += String(Character(scalar)) + "\t" + names(sets[scalar]!).joined(separator: " ") + "\n"
        }
        return text
    }

    /// How many characters each set has, overall and among `used`.
    func report(used: Set<Unicode.Scalar>) -> Report.Charsets {
        var all: [String: Int] = [:]
        var inLexicon: [String: Int] = [:]
        for (scalar, bits) in sets {
            for name in names(bits) {
                all[name, default: 0] += 1
                if used.contains(scalar) { inLexicon[name, default: 0] += 1 }
            }
        }
        let outside = used.filter { sets[$0] == nil }.count
        return Report.Charsets(unicode: version, characters: all, lexiconCharacters: used.count,
                               lexiconCharactersBySet: inLexicon, lexiconCharactersInNoSet: outside)
    }
}
