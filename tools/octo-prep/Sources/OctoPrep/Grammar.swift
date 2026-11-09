import Foundation

/// 万象's grammar model, as librime-octagram stores it (a .gram file):
///
///   0   "Rime::Grammar/1.0", NUL-padded to 32 bytes
///   32  u32 checksum (unused), u32 units in the array, i32 offset of the
///       array from this field (librime's OffsetPtr)
///   ..  a darts-clone double-array trie of u32 units
///
/// Each key is some characters of context followed by the start of a word,
/// or a word followed by "$" (how likely it ends a sentence), in octagram's
/// own encoding; each value is ln(score) × 10000, at least 0.
///
/// librime-octagram scores a word after its context like this (Query):
///   result = the non-collocation penalty
///   for each suffix of the context's last n characters (n = min(8, max length - 1)),
///     for each prefix of the word's first n characters that, after that suffix, is a key:
///       result = max(result, value / 10000 + (the collocation penalty, or the weak
///                    collocation penalty when the two are shorter than the min length
///                    and are not the whole query))
///   at the end of the input, if the word is at most n characters and word + "$" is a key:
///     result = max(result, value / 10000 + the rear penalty)
///
/// So under given settings most keys can never change a result: one that
/// cannot beat the non-collocation penalty, or that is longer than 2n
/// characters. Reading keeps only the keys that can; the rest change no
/// result, so leaving them out loses nothing.
public enum GrammarModel {
    /// The scheme's grammar settings (librime-octagram's GrammarConfig).
    public struct Settings: Equatable, Sendable {
        public var maxLength = 4
        public var minLength = 3
        public var collocationPenalty = -12.0
        public var nonCollocationPenalty = -12.0
        public var weakCollocationPenalty = -24.0
        public var rearPenalty = -18.0
        public init() {}

        /// Context characters a query reads, and word characters.
        public var span: Int { min(8, maxLength - 1) }

    }

    /// What a schema says about its grammar: the model's name (its file is
    /// <language>.gram), its settings (the top-level grammar: block; keys it
    /// leaves out keep librime-octagram's defaults), and the homophones the
    /// translator keeps for the sentence search (translator/max_homophones,
    /// librime's default 1).
    public static func schema(_ text: String) throws -> (language: String, settings: Settings, homophones: Int) {
        guard let grammar = try block("grammar", in: text), let language = grammar["language"]?.string else {
            throw AlgebraError(description: "the schema has no grammar: block with a language")
        }
        func number(_ node: YAMLNode?, _ key: String) throws -> Double? {
            guard let text = node?[key]?.string else { return nil }
            guard let v = Double(text) else { throw AlgebraError(description: "\(key): not a number: \(text)") }
            return v
        }
        var s = Settings()
        if let v = try number(grammar, "collocation_max_length") { s.maxLength = Int(v) }
        if let v = try number(grammar, "collocation_min_length") { s.minLength = Int(v) }
        if let v = try number(grammar, "collocation_penalty") { s.collocationPenalty = v }
        if let v = try number(grammar, "non_collocation_penalty") { s.nonCollocationPenalty = v }
        if let v = try number(grammar, "weak_collocation_penalty") { s.weakCollocationPenalty = v }
        if let v = try number(grammar, "rear_penalty") { s.rearPenalty = v }
        guard s.maxLength >= 2 && s.maxLength <= 9 && s.minLength >= 1 else {
            throw AlgebraError(description: "grammar: collocation lengths out of range")
        }
        let homophones = try number(try block("translator", in: text), "max_homophones").map { Int($0) } ?? 1
        guard homophones >= 1 && homophones <= 64 else {
            throw AlgebraError(description: "translator/max_homophones out of range")
        }
        return (language, s, homophones)
    }

    /// A top-level block of a schema, parsed alone: the whole schema uses
    /// YAML the subset parser does not need to know.
    static func block(_ name: String, in text: String) throws -> YAMLNode? {
        var lines: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if lines.isEmpty {
                if line.hasPrefix("\(name):") { lines.append(line) }
            } else if let first = line.first, first != " ", first != "#" {
                break
            } else {
                lines.append(line)
            }
        }
        return lines.isEmpty ? nil : try YAML.parse(lines.joined(separator: "\n"))[name]
    }

    /// The size of the .gram file at `path`, after checking its header and
    /// that its double array lies inside it.
    public static func check(_ path: String) throws -> Int {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            throw AlgebraError(description: "cannot read \(path)")
        }
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        let head = handle.readData(ofLength: headerSize)
        guard head.count == headerSize, String(decoding: head.prefix(format.utf8.count), as: UTF8.self) == format else {
            throw AlgebraError(description: "\(path) is not a librime grammar (.gram) file")
        }
        let units = Int(head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 36, as: UInt32.self) })
        let offset = Int(head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 40, as: Int32.self) })
        guard units >= 256, 40 + offset >= headerSize, 40 + offset + units * 4 <= size else {
            throw AlgebraError(description: "\(path): its double array lies outside the file")
        }
        return size
    }

    /// grammar.tsv, which octo-compile turns into grammar.img.
    public static func settingsTSV(language: String, settings s: Settings, homophones: Int, fileSize: Int) -> String {
        """
        # 万象's grammar model: which .gram file, and the schema's settings for it
        # (octo-prep, from wanxiang.schema.yaml). octo-compile writes grammar.img.
        language\t\(language)
        file_size\t\(fileSize)
        collocation_max_length\t\(s.maxLength)
        collocation_min_length\t\(s.minLength)
        collocation_penalty\t\(s.collocationPenalty)
        non_collocation_penalty\t\(s.nonCollocationPenalty)
        weak_collocation_penalty\t\(s.weakCollocationPenalty)
        rear_penalty\t\(s.rearPenalty)
        max_homophones\t\(homophones)

        """
    }

    public struct Stats: Sendable {
        public var keys = 0              // in the trie
        public var kept = 0
        public var keptRear = 0
        public var keptByLength: [Int: Int] = [:]
        public var tooLong = 0
        public var tooWeak = 0
        public var undecodable = 0
    }

    public static let format = "Rime::Grammar/"
    static let headerSize = 44

    /// Calls `keep` with every key that can change a result under
    /// `settings`, as Unicode scalars ("$" last for an end-of-input key),
    /// and its value. Throws if `data` is not a .gram file or its trie
    /// points outside itself.
    public static func read(_ data: Data, settings: Settings,
                            keep: ([Unicode.Scalar], Int32) -> Void) throws -> Stats {
        guard data.count >= headerSize,
              String(decoding: data.prefix(format.utf8.count), as: UTF8.self) == format else {
            throw AlgebraError(description: "not a librime grammar (.gram) file")
        }
        func u32(_ at: Int) -> UInt32 {
            data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: at, as: UInt32.self) }
        }
        let units = Int(u32(36))
        let offset = Int(Int32(bitPattern: u32(40)))
        let start = 40 + offset
        guard units >= 256, start >= headerSize, start + units * 4 <= data.count else {
            throw AlgebraError(description: "the grammar's double array is out of the file's bounds")
        }
        let span = settings.span
        // A collocation counts only if it can beat the non-collocation
        // penalty: value / 10000 + penalty > non-collocation.
        let strongest = max(settings.collocationPenalty, settings.weakCollocationPenalty)
        let collocationFloor = Int32(clamping: Int(((settings.nonCollocationPenalty - strongest) * 10000).rounded(.down)))
        let rearFloor = Int32(clamping: Int(((settings.nonCollocationPenalty - settings.rearPenalty) * 10000).rounded(.down)))
        var stats = Stats()

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: start)
            let array = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt32.self), count: units)
            @inline(__always) func label(_ u: UInt32) -> UInt32 { u & ((1 << 31) | 0xFF) }
            @inline(__always) func hasLeaf(_ u: UInt32) -> Bool { (u >> 8) & 1 == 1 }
            @inline(__always) func offsetOf(_ u: UInt32) -> Int { Int((u >> 10) << ((u & (1 << 9)) >> 6)) }

            // Depth first, keeping the key's bytes; a key longer than any
            // query can use is not followed further.
            var key: [UInt8] = []
            var stack: [(id: Int, next: Int)] = [(0, 1)]     // node, next label to try
            let maxBytes = (2 * span + 1) * 6                 // the longest a usable key can encode to
            func visitLeaf(_ id: Int) throws {
                let unit = array[id]
                let leaf = id ^ offsetOf(unit)
                guard leaf < units else { throw AlgebraError(description: "a grammar leaf is out of bounds") }
                let value = Int32(bitPattern: array[leaf] & ((1 << 31) - 1))
                stats.keys += 1
                guard let scalars = decode(key) else {
                    stats.undecodable += 1
                    return
                }
                let rear = scalars.last == "$"
                let chars = scalars.count - (rear ? 1 : 0)
                if rear ? (chars < 1 || chars > span) : (chars < 2 || chars > 2 * span) {
                    stats.tooLong += 1
                    return
                }
                if value <= (rear ? rearFloor : collocationFloor) {
                    stats.tooWeak += 1
                    return
                }
                stats.kept += 1
                if rear { stats.keptRear += 1 } else { stats.keptByLength[chars, default: 0] += 1 }
                keep(scalars, value)
            }
            if hasLeaf(array[0]) { try visitLeaf(0) }
            // Invariant: key holds the labels from the root to the node on top.
            while let top = stack.last {
                let childBase = top.id ^ offsetOf(array[top.id])
                var c = top.next
                var found = -1
                while c <= 0xFF {
                    let child = childBase ^ c
                    if child < units && label(array[child]) == UInt32(c) {
                        found = child
                        break
                    }
                    c += 1
                }
                if found < 0 {
                    stack.removeLast()
                    if !key.isEmpty { key.removeLast() }
                    continue
                }
                stack[stack.count - 1].next = c + 1
                key.append(UInt8(c))
                if hasLeaf(array[found]) { try visitLeaf(found) }
                if key.count < maxBytes {
                    stack.append((found, 1))
                } else {
                    key.removeLast()
                }
            }
        }
        return stats
    }

    /// Keys read from a model: their characters back to back, where each
    /// starts, and their values; sentence ends ("word$") apart.
    public struct Keys: Sendable {
        public var chars: [UInt32] = []
        public var starts: [UInt32] = [0]
        public var values: [Int32] = []
        public var rear: [([Unicode.Scalar], Int32)] = []
        public init() {}
        public var count: Int { values.count }
        public func key(_ i: Int) -> ArraySlice<UInt32> { chars[Int(starts[i])..<Int(starts[i + 1])] }

        public mutating func add(_ key: [Unicode.Scalar], _ value: Int32) {
            if key.last == "$" {
                rear.append((key, value))
            } else {
                chars.append(contentsOf: key.map(\.value))
                starts.append(UInt32(chars.count))
                values.append(value)
            }
        }
    }

    static func fingerprint<C: Collection>(_ key: C) -> UInt64 where C.Element == UInt32 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for c in key {
            h = (h ^ UInt64(c)) &* 0x0000_0100_0000_01B3
            h = (h ^ (h >> 29)) &* 0xBF58_476D_1CE4_E5B9
        }
        return h ^ UInt64(key.count)
    }

    /// The keys that can raise some query's result, given all the others.
    /// A query reads a key as a context suffix of L characters and a word
    /// prefix of n - L, both at most `span`. A shorter key inside it, that
    /// keeps at least one character on each side of the split, matches
    /// whenever it does; if that one is worth as much, this key never wins
    /// the maximum for that split. A key no split needs is left out, and no
    /// query's result changes.
    public static func reduce(_ keys: Keys, span: Int) -> [Int] {
        var index: [UInt64: Int32] = [:]
        index.reserveCapacity(keys.count)
        for i in 0..<keys.count { index[fingerprint(keys.key(i))] = keys.values[i] }
        var kept: [Int] = []
        for i in 0..<keys.count {
            let k = Array(keys.key(i))
            let n = k.count
            let v = keys.values[i]
            var needed = false
            for split in 1..<n where split <= span && n - split <= span {
                var dominated = false
                outer: for a in 0..<split {
                    for e in (split + 1)...n where !(a == 0 && e == n) {
                        if let w = index[fingerprint(k[a..<e])], w >= v {
                            dominated = true
                            break outer
                        }
                    }
                }
                if !dominated {
                    needed = true
                    break
                }
            }
            if needed { kept.append(i) }
        }
        return kept
    }

    /// grammar.tsv: a header naming the model and its settings, then each
    /// kept key and its value, sorted by key so the file is the same every
    /// time. Returns the bytes written.
    public static func writeTSV(_ rows: [(String, Int32)], language: String, settings: Settings,
                                to path: String) throws -> Int {
        var out = "#grammar\t\(language)\tmax_length=\(settings.maxLength)\tmin_length=\(settings.minLength)" +
            "\tcollocation=\(settings.collocationPenalty)\tnon_collocation=\(settings.nonCollocationPenalty)" +
            "\tweak_collocation=\(settings.weakCollocationPenalty)\trear=\(settings.rearPenalty)\n" +
            "# value (ln × 10000)\tkey: context then the start of a word, or a word then $ for a sentence end\n"
        for (key, value) in rows.sorted(by: { Array($0.0.utf8).lexicographicallyPrecedes(Array($1.0.utf8)) }) {
            out += "\(value)\t\(key)\n"
        }
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        let data = Data(out.utf8)
        try data.write(to: URL(fileURLWithPath: path))
        return data.count
    }

    /// Octagram's key encoding back to Unicode scalars (gram_encoding.cc):
    ///   00-7F        ASCII
    ///   80-DF xx     U+4000-U+9FFF: (high byte + 0x40) then the low byte
    ///   E0           U+0000
    ///   E1 hh        U+4000-U+9FFF whose low byte is 0
    ///   E2-E5 ...    any other: 2 to 5 bytes of 7 bits each, the scalar's
    ///                bits left-aligned, so the value is their bits >> 3
    public static func decode(_ bytes: [UInt8]) -> [Unicode.Scalar]? {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < bytes.count {
            let b = bytes[i]
            var value: UInt32
            if b < 0x80 {
                value = UInt32(b)
                i += 1
            } else if b < 0xE0 {
                guard i + 1 < bytes.count else { return nil }
                value = (UInt32(b) - 0x40) << 8 | UInt32(bytes[i + 1])
                i += 2
            } else if b == 0xE0 {
                value = 0
                i += 1
            } else if b == 0xE1 {
                guard i + 1 < bytes.count, bytes[i + 1] >= 0x80 else { return nil }
                value = (UInt32(bytes[i + 1]) - 0x40) << 8
                i += 2
            } else if b <= 0xE5 {
                let n = Int(b & 0x0F)
                guard i + n < bytes.count else { return nil }
                var v: UInt64 = 0
                for k in 1...n {
                    guard bytes[i + k] & 0x80 != 0 else { return nil }
                    v = v << 7 | UInt64(bytes[i + k] & 0x7F)
                }
                value = UInt32(truncatingIfNeeded: v >> 3)
                i += n + 1
            } else {
                return nil
            }
            guard let scalar = Unicode.Scalar(value) else { return nil }
            out.append(scalar)
        }
        return out
    }

    /// Octagram's encoding of `scalars`, for tests and round trips.
    public static func encode(_ scalars: [Unicode.Scalar]) -> [UInt8] {
        var out: [UInt8] = []
        for s in scalars {
            var u = s.value
            if u < 0x80 {
                out.append(u == 0 ? 0xE0 : UInt8(u))
            } else if u >= 0x4000 && u < 0xA000 {
                if u & 0xFF == 0 {
                    out += [0xE1, UInt8((u >> 8) + 0x40)]
                } else {
                    out += [UInt8((u >> 8) + 0x40), UInt8(u & 0xFF)]
                }
            } else {
                var bits = 32
                while bits > 0 && (u & 0xFE00_0000) == 0 {
                    bits -= 7
                    u <<= 7
                }
                var n = (bits + 6) / 7
                out.append(0xE0 | UInt8(n))
                while n > 0 {
                    n -= 1
                    out.append(UInt8((u >> 25) & 0x7F) | 0x80)
                    u <<= 7
                }
            }
        }
        return out
    }
}
