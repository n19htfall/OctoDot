import Foundation

/// 万象's auxiliary (shape) codes, from custom/aux_code.csv: one row per
/// character and one column per scheme. A cell holds one or more
/// alternatives, separated by ｜ or, inside a quoted cell, by commas. Each
/// alternative is the components it was derived from, then the code itself:
/// "口可 kk", "爫夊vw｜心夊xw", or a bare code.
struct AuxCodes {
    /// Header names → the names used in OctoDot's files (aux.<name>.img).
    static let names: [String: String] = [
        "万象": "wanxiang", "墨奇": "moqi", "野鹤": "yehe", "自然码": "zrm", "虎码首末": "huma",
        "五笔前2": "wubi", "汉心码": "hanxin", "首右": "shouyou", "首右Plus": "shouyou-plus",
    ]
    static let longestCode = 7

    var schemes: [String] = []                  // in column order
    var titles: [String] = []                   // their names in the header: 万象, 墨奇, …
    var codes: [Unicode.Scalar: [[String]]] = [:]   // character → its codes, per scheme
    var rows = 0
    var issues: [Report.Issue] = []

    /// The code an alternative ends with: its trailing ASCII letters,
    /// lowercased; nil if it has none or too many.
    static func code(of alternative: Substring) -> String? {
        let letters = alternative.reversed().prefix { $0.isASCII && $0.isLetter }
        guard !letters.isEmpty, letters.count <= longestCode else { return nil }
        return String(letters.reversed()).lowercased()
    }

    /// A cell's codes, in order, without repeats.
    static func codes(inCell cell: String) -> [String] {
        var out: [String] = []
        for alternative in cell.split(whereSeparator: { $0 == "｜" || $0 == "," }) {
            if let c = code(of: alternative), !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// RFC 4180 fields: commas separate, quotes enclose, "" is a quote.
    static func fields(_ line: Substring) -> [String] {
        var out: [String] = []
        var field = ""
        var quoted = false
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if quoted {
                if c == "\"" {
                    let next = line.index(after: i)
                    if next < line.endIndex && line[next] == "\"" {
                        field.append("\"")
                        i = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                quoted = true
            } else if c == "," {
                out.append(field)
                field = ""
            } else {
                field.append(c)
            }
            i = line.index(after: i)
        }
        out.append(field)
        return out
    }

    init(path: String) throws {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw AlgebraError(description: "cannot read \(path)")
        }
        var log: [String: Report.Issue] = [:]
        var order: [String] = []
        func note(_ reason: String, dropped: Bool, _ line: Int, _ raw: Substring) {
            if log[reason] == nil {
                log[reason] = Report.Issue(reason: reason, dropped: dropped, count: 0, examples: [])
                order.append(reason)
            }
            log[reason]!.count += 1
            if log[reason]!.examples.count < 5 { log[reason]!.examples.append("aux_code.csv:\(line): \(raw)") }
        }

        var lineNumber = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            let line = raw.hasSuffix("\r") ? raw.dropLast() : raw
            if line.isEmpty { continue }
            let cells = AuxCodes.fields(line)
            if lineNumber == 1 {
                titles = Array(cells.dropFirst())
                schemes = try cells.dropFirst().map { name in
                    guard let short = AuxCodes.names[name] else {
                        throw AlgebraError(description: "aux_code.csv: unknown scheme \"\(name)\" in the header")
                    }
                    return short
                }
                continue
            }
            rows += 1
            let character = cells[0].precomposedStringWithCanonicalMapping.unicodeScalars
            guard character.count == 1, let scalar = character.first else {
                note("not one character", dropped: true, lineNumber, line)
                continue
            }
            if cells.count != schemes.count + 1 {
                note("wrong number of columns; the columns present are used", dropped: false, lineNumber, line)
            }
            var perScheme = codes[scalar] ?? Array(repeating: [], count: schemes.count)
            if codes[scalar] != nil { note("character listed again; its codes are merged", dropped: false, lineNumber, line) }
            for s in schemes.indices where s + 1 < cells.count {
                let cell = cells[s + 1]
                let found = AuxCodes.codes(inCell: cell)
                if found.isEmpty && !cell.trimmingCharacters(in: .whitespaces).isEmpty {
                    note("a cell with no code in it", dropped: true, lineNumber, line)
                }
                for c in found where !perScheme[s].contains(c) { perScheme[s].append(c) }
            }
            codes[scalar] = perScheme
        }
        guard !schemes.isEmpty else { throw AlgebraError(description: "aux_code.csv: no header") }
        issues = order.map { log[$0]! }
    }

    /// The normalized table: a header naming the schemes, then one line per
    /// character in code point order, each scheme's codes space-separated.
    func tsv() -> String {
        var text = "# char\t" + schemes.joined(separator: "\t") + "\n"
        text += "# names\t" + titles.joined(separator: "\t") + "\n"
        for scalar in codes.keys.sorted(by: { $0.value < $1.value }) {
            text += String(Character(scalar))
            for list in codes[scalar]! { text += "\t" + list.joined(separator: " ") }
            text += "\n"
        }
        return text
    }

    var report: Report.Aux {
        var perScheme: [String: Int] = [:]
        for (s, name) in schemes.enumerated() {
            perScheme[name] = codes.values.reduce(0) { $0 + ($1[s].isEmpty ? 0 : 1) }
        }
        return Report.Aux(file: "custom/aux_code.csv", rows: rows, characters: codes.count,
                          charactersByScheme: perScheme, issues: issues)
    }
}
