import Foundation

// Rime's spelling algebra, evaluated as librime evaluates it
// (src/rime/algo/calculus.cc, algebra.cc and spelling.cc), so the spellings
// OctoDot ships match those a Rime user of the same scheme gets.
//
// Two details make that exact rather than approximate:
//   * librime runs Boost regex over the UTF-8 bytes of a spelling. Patterns
//     and spellings are matched here as Latin-1 text holding one character
//     per byte, so `.`, character classes and lengths behave byte by byte.
//   * Replacements use Boost's Perl format, not ICU's template syntax
//     (Boost's `\u` uppercases the next character, for one), so they are
//     expanded by the interpreter below.

/// librime's SpellingType, in its order: a smaller type is a better spelling.
public enum SpellingType: Int, Comparable, Sendable {
    case normal = 0, fuzzy, abbreviation, completion, ambiguous, invalid

    public static func < (a: SpellingType, b: SpellingType) -> Bool { a.rawValue < b.rawValue }

    public var name: String {
        ["normal", "fuzzy", "abbrev", "completion", "ambiguous", "invalid"][rawValue]
    }
}

/// librime's SpellingProperties, without the fields the algebra never sets.
public struct SpellingProperties: Equatable, Sendable {
    public var type: SpellingType
    public var credibility: Double  // a log probability: 0, or a penalty below 0
    public var isCorrection: Bool

    public init(type: SpellingType = .normal, credibility: Double = 0, isCorrection: Bool = false) {
        self.type = type
        self.credibility = credibility
        self.isCorrection = isCorrection
    }

    /// SpellingProperties::Compose: a rule's effect, applied on top.
    mutating func compose(_ delta: SpellingProperties) {
        if delta.type > type { type = delta.type }
        credibility += delta.credibility
        if delta.isCorrection { isCorrection = true }
    }

    /// SpellingProperties::Update: a second derivation reaching the same
    /// spelling of the same syllable. The better type and credibility win.
    mutating func update(_ other: SpellingProperties) {
        if type == other.type {
            isCorrection = isCorrection && other.isCorrection
        } else if other.type < type {
            type = other.type
            isCorrection = other.isCorrection
        }
        if other.credibility > credibility { credibility = other.credibility }
    }
}

/// A syllable a spelling spells, and the fuzzy groups (模糊音, bits) its
/// derivation went through: 0 for an exact spelling. Derivations needing
/// different groups are kept apart, never merged, so the engine can offer
/// each only while the user has its groups on (docs/fuzzy-pinyin.md).
public struct Origin: Hashable, Sendable {
    public var syllable: String
    public var fuzzy: UInt32

    public init(_ syllable: String, fuzzy: UInt32 = 0) {
        self.syllable = syllable
        self.fuzzy = fuzzy
    }
}

/// librime's Script: each spelling, and the syllables it spells.
public typealias Script = [String: [Origin: SpellingProperties]]

extension Dictionary where Key == Origin, Value == SpellingProperties {
    /// The syllable as spelled with no fuzzy group.
    public subscript(_ syllable: String) -> SpellingProperties? { self[Origin(syllable)] }
}

public struct AlgebraError: Error, CustomStringConvertible {
    public let description: String
}

/// One formula, such as `derive/^([jqxy])u$/$1v/`.
public final class Rule {
    public enum Kind: String { case xlit, xform, erase, derive, fuzz, abbrev }

    public let kind: Kind
    public let definition: String
    /// The fuzzy group (a bit) this rule belongs to, or 0. A fuzzy group's
    /// rules make fuzzy spellings, as librime's fuzz does (a fuzzy type, a
    /// penalty), whatever their operator: 万象 writes them as derive, which
    /// would give a fuzzy spelling the standing of the exact one.
    public var fuzzyGroup: UInt32 = 0
    private let regex: NSRegularExpression?
    private let template: [TemplatePart]
    private let characterMap: [Unicode.Scalar: Unicode.Scalar]

    static let abbreviationPenalty = log(0.5)   // calculus.cc: kAbbreviationPenalty
    static let fuzzySpellingPenalty = log(0.5)  // calculus.cc: kFuzzySpellingPenalty

    /// Calculus::Parse. The operator is the leading run of lowercase letters,
    /// the next character separates the arguments, and there is no escaping
    /// (boost::split on that character).
    public init(_ definition: String) throws {
        self.definition = definition
        let bytes = Array(definition.utf8)
        guard let sepIndex = bytes.firstIndex(where: { !(0x61...0x7A).contains($0) }) else {
            throw AlgebraError(description: "no separator in '\(definition)'")
        }
        let separator = bytes[sepIndex]
        guard separator < 0x80 else {
            throw AlgebraError(description: "non-ASCII separator in '\(definition)'")
        }
        let args = bytes.split(separator: separator, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard let kind = Kind(rawValue: args[0]) else {
            throw AlgebraError(description: "unsupported operator '\(args[0])' in '\(definition)'")
        }
        self.kind = kind

        switch kind {
        case .xlit:
            guard args.count >= 3 else { throw AlgebraError(description: "xlit needs two arguments: '\(definition)'") }
            let left = Array(args[1].unicodeScalars), right = Array(args[2].unicodeScalars)
            guard left.count == right.count, !left.isEmpty else {
                throw AlgebraError(description: "xlit arguments differ in length: '\(definition)'")
            }
            var map: [Unicode.Scalar: Unicode.Scalar] = [:]
            for (l, r) in zip(left, right) { map[l] = r }
            characterMap = map
            regex = nil
            template = []
        case .erase:
            guard args.count >= 2, !args[1].isEmpty else {
                throw AlgebraError(description: "erase needs a pattern: '\(definition)'")
            }
            // regex_match: the whole spelling must match.
            regex = try Rule.compile("^(?:" + args[1] + ")\\z", definition)
            template = []
            characterMap = [:]
        case .xform, .derive, .fuzz, .abbrev:
            guard args.count >= 3, !args[1].isEmpty else {
                throw AlgebraError(description: "\(kind.rawValue) needs a pattern and a replacement: '\(definition)'")
            }
            regex = try Rule.compile(args[1], definition)
            template = TemplatePart.parse(ByteText.view(args[2]))
            characterMap = [:]
        }
    }

    /// Erasion drops the spelling; Derivation and its kinds keep the original.
    var addition: Bool { kind != .erase }
    var deletion: Bool { kind == .xlit || kind == .xform || kind == .erase }

    /// The rule applied to one spelling: nil if it does not apply, otherwise
    /// the new spelling ("" when erased) and the properties the rule adds.
    func apply(_ spelling: String) throws -> (String, SpellingProperties)? {
        guard !spelling.isEmpty else { return nil }
        switch kind {
        case .xlit:
            var found = false
            var out = String.UnicodeScalarView()
            for scalar in spelling.unicodeScalars {
                if let mapped = characterMap[scalar] {
                    out.append(mapped)
                    found = true
                } else {
                    out.append(scalar)
                }
            }
            return found ? (String(out), SpellingProperties()) : nil
        case .erase:
            let view = ByteText.view(spelling)
            let range = NSRange(location: 0, length: (view as NSString).length)
            return regex!.firstMatch(in: view, range: range) != nil ? ("", SpellingProperties()) : nil
        case .xform, .derive, .fuzz, .abbrev:
            let result = try replaceAll(spelling)
            guard !result.utf8.elementsEqual(spelling.utf8) else { return nil }
            var delta = SpellingProperties()
            if kind == .fuzz || fuzzyGroup != 0 {
                delta.type = .fuzzy
                delta.credibility = Rule.fuzzySpellingPenalty
            } else if kind == .abbrev {
                delta.type = .abbreviation
                delta.credibility = Rule.abbreviationPenalty
            }
            return (result, delta)
        }
    }

    /// boost::regex_replace with the default flags: every match replaced.
    private func replaceAll(_ spelling: String) throws -> String {
        let view = ByteText.view(spelling)
        let ns = view as NSString
        let matches = regex!.matches(in: view, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return spelling }
        var out = ""
        var last = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            out += TemplatePart.expand(template, match, ns)
            last = match.range.location + match.range.length
        }
        out += ns.substring(from: last)
        guard let result = ByteText.string(out) else {
            throw AlgebraError(description: "'\(definition)' turns '\(spelling)' into invalid UTF-8")
        }
        return result
    }

    private static func compile(_ pattern: String, _ definition: String) throws -> NSRegularExpression {
        do {
            // Only "\n" ends a line: as bytes, U+0085 is part of a character.
            return try NSRegularExpression(pattern: ByteText.view(pattern), options: [.useUnixLineSeparators])
        } catch {
            throw AlgebraError(description: "bad pattern in '\(definition)': \(error.localizedDescription)")
        }
    }
}

/// Projection::Apply on a Script: each rule in turn rewrites every spelling,
/// starting from the syllables spelled as themselves.
public func project(syllables: [String], rules: [Rule]) throws -> Script {
    var script: Script = [:]
    for syllable in syllables where script[syllable] == nil {
        script[syllable] = [Origin(syllable): SpellingProperties()]
    }
    for rule in rules {
        var next: Script = [:]
        next.reserveCapacity(script.count)
        for (spelling, origins) in script {
            if let (result, delta) = try rule.apply(spelling) {
                if !rule.deletion { merge(into: &next, spelling, SpellingProperties(), origins, adding: 0) }
                if rule.addition && !result.isEmpty {
                    merge(into: &next, result, delta, origins, adding: rule.fuzzyGroup)
                }
            } else {
                merge(into: &next, spelling, SpellingProperties(), origins, adding: 0)
            }
        }
        script = next
    }
    return pruned(script)
}

/// Script::Merge, the fuzzy groups of the rule applied joining each origin's.
private func merge(into script: inout Script, _ spelling: String, _ delta: SpellingProperties,
                   _ origins: [Origin: SpellingProperties], adding group: UInt32) {
    for (origin, properties) in origins {
        var composed = properties
        composed.compose(delta)
        let key = Origin(origin.syllable, fuzzy: origin.fuzzy | group)
        if script[spelling]?[key] != nil {
            script[spelling]![key]!.update(composed)
        } else {
            script[spelling, default: [:]][key] = composed
        }
    }
}

/// Drops each fuzzy derivation another of the same syllable makes useless:
/// one needing a subset of its groups, with as good a type and credibility
/// (an abbreviation of zhong reached through the fuzzy zong, beside the
/// plain one).
private func pruned(_ script: Script) -> Script {
    var out = script
    for (spelling, origins) in script where origins.count > 1 {
        for (origin, p) in origins where origin.fuzzy != 0 {
            let dominated = origins.contains { other, q in
                other.syllable == origin.syllable && other.fuzzy != origin.fuzzy &&
                    other.fuzzy & origin.fuzzy == other.fuzzy && q.type <= p.type && q.credibility >= p.credibility
            }
            if dominated { out[spelling]![origin] = nil }
        }
    }
    return out
}

/// Text as Boost sees it: one character per UTF-8 byte.
enum ByteText {
    static func view(_ s: String) -> String {
        String(String.UnicodeScalarView(s.utf8.map { Unicode.Scalar($0) }))
    }

    /// The UTF-8 text a byte view holds, or nil if it is not valid UTF-8.
    static func string(_ view: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(view.unicodeScalars.count)
        for scalar in view.unicodeScalars {
            guard scalar.value <= 0xFF else { return nil }
            bytes.append(UInt8(scalar.value))
        }
        return String(bytes: bytes, encoding: .utf8)
    }
}

/// A replacement in Boost's Perl format: `$n`, `${n}`, `$&`, `` $` ``, `$'`,
/// `$$`, the case escapes `\u \l \U \L \E`, control escapes and `\xHH`; any
/// other escaped character stands for itself.
enum TemplatePart: Equatable {
    case literal(String)
    case group(Int)
    case prefix, suffix
    case upperNext, lowerNext, upperRun, lowerRun, endRun

    static func parse(_ view: String) -> [TemplatePart] {
        var parts: [TemplatePart] = []
        var literal = String.UnicodeScalarView()
        func flush() {
            if !literal.isEmpty { parts.append(.literal(String(literal))); literal = String.UnicodeScalarView() }
        }
        let s = Array(view.unicodeScalars)
        let digits: ClosedRange<Unicode.Scalar> = "0"..."9"
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "$", i + 1 < s.count {
                let n = s[i + 1]
                if digits.contains(n) {
                    var j = i + 1, value = 0
                    while j < s.count, j < i + 3, digits.contains(s[j]) { value = value * 10 + Int(s[j].value - 48); j += 1 }
                    flush(); parts.append(.group(value)); i = j; continue
                }
                if n == "{", let close = s[(i + 2)...].firstIndex(of: "}"), close > i + 2,
                   s[(i + 2)..<close].allSatisfy({ digits.contains($0) }) {
                    let value = s[(i + 2)..<close].reduce(0) { $0 * 10 + Int($1.value - 48) }
                    flush(); parts.append(.group(value)); i = close + 1; continue
                }
                switch n {
                case "&": flush(); parts.append(.group(0)); i += 2; continue
                case "`": flush(); parts.append(.prefix); i += 2; continue
                case "'": flush(); parts.append(.suffix); i += 2; continue
                case "$": literal.append("$"); i += 2; continue
                default: break
                }
            }
            if c == "\\", i + 1 < s.count {
                let n = s[i + 1]
                i += 2
                switch n {
                case "u": flush(); parts.append(.upperNext)
                case "l": flush(); parts.append(.lowerNext)
                case "U": flush(); parts.append(.upperRun)
                case "L": flush(); parts.append(.lowerRun)
                case "E": flush(); parts.append(.endRun)
                case "a": literal.append("\u{07}")
                case "e": literal.append("\u{1B}")
                case "f": literal.append("\u{0C}")
                case "n": literal.append("\n")
                case "r": literal.append("\r")
                case "t": literal.append("\t")
                case "v": literal.append("\u{0B}")
                case "x":
                    var j = i, value: UInt32 = 0
                    while j < s.count, j < i + 2, let d = UInt32(String(s[j]), radix: 16) { value = value * 16 + d; j += 1 }
                    if j > i, let scalar = Unicode.Scalar(value) { literal.append(scalar); i = j } else { literal.append("x") }
                default: literal.append(n)
                }
                continue
            }
            literal.append(c)
            i += 1
        }
        flush()
        return parts
    }

    static func expand(_ parts: [TemplatePart], _ match: NSTextCheckingResult, _ text: NSString) -> String {
        var out = String.UnicodeScalarView()
        var next: Bool? = nil  // true: uppercase the next character
        var run: Bool? = nil   // true: uppercase until \E
        func emit(_ piece: String) {
            for var scalar in piece.unicodeScalars {
                if let upper = next {
                    scalar = asciiCase(scalar, upper: upper)
                    next = nil
                } else if let upper = run {
                    scalar = asciiCase(scalar, upper: upper)
                }
                out.append(scalar)
            }
        }
        for part in parts {
            switch part {
            case .literal(let text): emit(text)
            case .group(let n):
                guard n < match.numberOfRanges else { continue }
                let range = match.range(at: n)
                if range.location != NSNotFound { emit(text.substring(with: range)) }
            case .prefix: emit(text.substring(to: match.range.location))
            case .suffix: emit(text.substring(from: match.range.location + match.range.length))
            case .upperNext: next = true
            case .lowerNext: next = false
            case .upperRun: run = true
            case .lowerRun: run = false
            case .endRun: run = nil
            }
        }
        return String(out)
    }

    /// Boost works on bytes in the C locale: only ASCII letters change case.
    private static func asciiCase(_ s: Unicode.Scalar, upper: Bool) -> Unicode.Scalar {
        if upper, ("a"..."z").contains(s) { return Unicode.Scalar(s.value - 32)! }
        if !upper, ("A"..."Z").contains(s) { return Unicode.Scalar(s.value + 32)! }
        return s
    }
}
