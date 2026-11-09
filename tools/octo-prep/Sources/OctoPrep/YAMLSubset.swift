/// The part of YAML that Rime's data files use: block mappings and block
/// sequences of plain or quoted scalars, flow sequences of scalars, and
/// comments. Anything else is an error naming the line, never a silent
/// misreading.
public indirect enum YAMLNode {
    case scalar(String)
    case list([YAMLNode])
    case map([(key: String, value: YAMLNode)])
    case null

    public subscript(key: String) -> YAMLNode? {
        guard case .map(let pairs) = self else { return nil }
        return pairs.first { $0.key == key }?.value
    }

    /// The node at a slash-separated path of keys, such as "base/全拼/__append".
    public func at(_ path: String) -> YAMLNode? {
        path.split(separator: "/").reduce(Optional(self)) { node, key in node?[String(key)] }
    }

    public var string: String? {
        if case .scalar(let s) = self { return s }
        return nil
    }

    /// A sequence of scalars; nil for anything else.
    public var strings: [String]? {
        guard case .list(let items) = self else { return nil }
        var out: [String] = []
        for item in items {
            guard let s = item.string else { return nil }
            out.append(s)
        }
        return out
    }
}

public struct YAMLError: Error, CustomStringConvertible {
    public let line: Int
    public let message: String
    public var description: String { "line \(line): \(message)" }
}

public enum YAML {
    /// Parses the first document in `text`. Reading stops at a "..." line.
    public static func parse(_ text: String) throws -> YAMLNode {
        var lines: [Line] = []
        var number = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            var content = Substring(raw)
            if content.hasSuffix("\r") { content = content.dropLast() }
            let indent = content.prefix { $0 == " " }.count
            let rest = content.dropFirst(indent)
            if rest.first == "\t" { throw YAMLError(line: number, message: "tab in indentation") }
            let trimmed = rest.trimmingTrailingSpaces()
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed == "---" { continue }
            if trimmed == "..." { break }
            lines.append(try Line(number: number, indent: indent, content: trimmed))
        }
        var parser = Parser(lines: lines)
        guard !lines.isEmpty else { return .null }
        let node = try parser.block(minimumIndent: 0)
        if parser.index < lines.count {
            throw YAMLError(line: lines[parser.index].number, message: "unexpected indentation")
        }
        return node
    }

    private struct Line {
        enum Kind { case item(Substring), pair(String, Substring) }
        let number: Int
        let indent: Int
        let kind: Kind

        init(number: Int, indent: Int, content: Substring) throws {
            self.number = number
            self.indent = indent
            if content == "-" {
                kind = .item("")
            } else if content.hasPrefix("- ") {
                kind = .item(content.dropFirst(2))
            } else if let colon = YAML.keySeparator(content) {
                let key = try YAML.scalar(content[..<colon], line: number) ?? ""
                kind = .pair(key, content[content.index(after: colon)...])
            } else {
                throw YAMLError(line: number, message: "expected a key or a list item")
            }
        }

        var isItem: Bool {
            if case .item = kind { return true }
            return false
        }
    }

    private struct Parser {
        let lines: [Line]
        var index = 0

        mutating func block(minimumIndent: Int) throws -> YAMLNode {
            let first = lines[index]
            guard first.indent >= minimumIndent else { return .null }
            return first.isItem ? try list(indent: first.indent) : try map(indent: first.indent)
        }

        mutating func list(indent: Int) throws -> YAMLNode {
            var items: [YAMLNode] = []
            while index < lines.count, lines[index].indent == indent, case .item(let rest) = lines[index].kind {
                let line = lines[index]
                index += 1
                if YAML.keySeparator(rest) != nil, !YAML.startsQuoted(rest) {
                    throw YAMLError(line: line.number, message: "mappings inside sequences are not supported")
                }
                if let value = try YAML.value(rest, line: line.number) {
                    items.append(value)
                } else if index < lines.count, lines[index].indent > indent {
                    items.append(try block(minimumIndent: indent + 1))
                } else {
                    items.append(.null)
                }
            }
            return .list(items)
        }

        mutating func map(indent: Int) throws -> YAMLNode {
            var pairs: [(key: String, value: YAMLNode)] = []
            while index < lines.count, lines[index].indent == indent, case .pair(let key, let rest) = lines[index].kind {
                let line = lines[index]
                index += 1
                if pairs.contains(where: { $0.key == key }) {
                    throw YAMLError(line: line.number, message: "duplicate key '\(key)'")
                }
                let value: YAMLNode
                if let v = try YAML.value(rest, line: line.number) {
                    value = v
                } else if index < lines.count, lines[index].indent > indent {
                    value = try block(minimumIndent: indent + 1)
                } else if index < lines.count, lines[index].indent == indent, lines[index].isItem {
                    value = try list(indent: indent)      // a sequence written at its key's indentation
                } else {
                    value = .null
                }
                pairs.append((key, value))
            }
            return .map(pairs)
        }
    }

    /// Where the key of `content` ends: the first ':' followed by a space or
    /// the end of the line, outside quotes.
    static func keySeparator(_ content: Substring) -> Substring.Index? {
        var quote: Character? = nil
        var i = content.startIndex
        while i < content.endIndex {
            let c = content[i]
            if let q = quote {
                if c == q { quote = nil }
            } else if (c == "'" || c == "\"") && i == content.startIndex {
                quote = c
            } else if c == ":" {
                let next = content.index(after: i)
                if next == content.endIndex || content[next] == " " { return i }
            } else if c == "#", i > content.startIndex, content[content.index(before: i)] == " " {
                return nil
            }
            i = content.index(after: i)
        }
        return nil
    }

    static func startsQuoted(_ s: Substring) -> Bool {
        let t = s.drop { $0 == " " }
        return t.first == "'" || t.first == "\""
    }

    /// A value after "key:" or "- ": a scalar or a flow sequence, or nil if
    /// there is none on this line.
    static func value(_ raw: Substring, line: Int) throws -> YAMLNode? {
        let s = raw.drop { $0 == " " }
        if s.isEmpty || s.hasPrefix("#") { return nil }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else {
                throw YAMLError(line: line, message: "unterminated flow sequence")
            }
            try expectEnd(s[s.index(after: close)...], line: line)
            let inner = s[s.index(after: s.startIndex)..<close]
            if inner.allSatisfy({ $0 == " " }) { return .list([]) }
            return .list(try inner.split(separator: ",", omittingEmptySubsequences: false).map {
                .scalar(try scalar($0, line: line) ?? "")
            })
        }
        if let first = s.first, "{&*|>!%@`".contains(first) {
            throw YAMLError(line: line, message: "unsupported YAML syntax '\(first)'")
        }
        return try scalar(s, line: line).map(YAMLNode.scalar)
    }

    /// A plain or quoted scalar with any trailing comment removed.
    static func scalar(_ raw: Substring, line: Int) throws -> String? {
        let s = raw.drop { $0 == " " }
        guard let first = s.first else { return nil }
        if first == "'" || first == "\"" {
            var out = ""
            var i = s.index(after: s.startIndex)
            while i < s.endIndex {
                let c = s[i]
                if c == first {
                    let next = s.index(after: i)
                    if first == "'", next < s.endIndex, s[next] == "'" {     // '' inside single quotes
                        out.append("'")
                        i = s.index(after: next)
                        continue
                    }
                    try expectEnd(s[next...], line: line)
                    return out
                }
                if first == "\"", c == "\\" {
                    i = s.index(after: i)
                    guard i < s.endIndex else { break }
                    switch s[i] {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\": out.append("\\")
                    case "\"": out.append("\"")
                    case "u":
                        let hexEnd = s.index(i, offsetBy: 5, limitedBy: s.endIndex) ?? s.endIndex
                        guard let code = UInt32(s[s.index(after: i)..<hexEnd], radix: 16),
                              let scalar = Unicode.Scalar(code) else {
                            throw YAMLError(line: line, message: "bad \\u escape")
                        }
                        out.unicodeScalars.append(scalar)
                        i = s.index(before: hexEnd)
                    default: out.append(s[i])
                    }
                } else {
                    out.append(c)
                }
                i = s.index(after: i)
            }
            throw YAMLError(line: line, message: "unterminated quoted scalar")
        }
        var end = s.endIndex
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "#", i > s.startIndex, s[s.index(before: i)] == " " || s[s.index(before: i)] == "\t" {
                end = i
                break
            }
            i = s.index(after: i)
        }
        let text = s[..<end].trimmingTrailingSpaces()
        return text.isEmpty ? nil : String(text)
    }

    private static func expectEnd(_ rest: Substring, line: Int) throws {
        let t = rest.drop { $0 == " " }
        if !t.isEmpty && !t.hasPrefix("#") {
            throw YAMLError(line: line, message: "unexpected text after a value")
        }
    }
}

extension Substring {
    func trimmingTrailingSpaces() -> Substring {
        var s = self
        while let last = s.last, last == " " || last == "\t" { s = s.dropLast() }
        return s
    }
}
