import Foundation

/// A Rime dictionary file (*.dict.yaml): a YAML header that ends at a "..."
/// line, then one entry per line with tab-separated columns.
public struct DictFile {
    public let path: String
    public let header: YAMLNode
    /// The header's `columns`, or Rime's default: text, code, weight, stem.
    public let columns: [String]
    let bytes: [UInt8]
    let bodyStart: Int
    let bodyFirstLine: Int

    public init(path: String) throws {
        self.path = path
        guard let data = FileManager.default.contents(atPath: path) else {
            throw AlgebraError(description: "cannot read \(path)")
        }
        bytes = [UInt8](data)
        var lineStart = 0, line = 1
        var end: (header: Int, body: Int)? = nil
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
            var content = bytes[lineStart..<lineEnd]
            while let last = content.last, last == 0x0D || last == 0x20 { content = content.dropLast() }
            if content.elementsEqual("...".utf8) {
                end = (lineStart, min(lineEnd + 1, bytes.count))
                break
            }
            lineStart = lineEnd + 1
            line += 1
        }
        guard let end else { throw AlgebraError(description: "\(path): no '...' line ends the header") }
        do {
            header = try YAML.parse(String(decoding: bytes[..<end.header], as: UTF8.self))
        } catch {
            throw AlgebraError(description: "\(path): header \(error)")
        }
        bodyStart = end.body
        bodyFirstLine = line + 1
        columns = header["columns"]?.strings ?? ["text", "code", "weight", "stem"]
        guard columns.contains("text") else { throw AlgebraError(description: "\(path): no text column") }
    }

    /// One entry line, its fields picked out by the columns.
    public struct Row {
        public let line: Int
        public let text: String
        public let code: String?    // nil when the row has none
        public let weight: String?  // nil when the row has none
        public let extraColumns: Int
    }

    /// The entries in file order. Lines starting with "#" are comments,
    /// unless a "# no comment" line has turned comments off, as in librime.
    public func forEachRow(_ body: (Row) throws -> Void) rethrows {
        let textColumn = columns.firstIndex(of: "text")!
        let codeColumn = columns.firstIndex(of: "code")
        let weightColumn = columns.firstIndex(of: "weight")
        var comments = true
        var lineStart = bodyStart, line = bodyFirstLine
        while lineStart < bytes.count {
            let lineEnd = bytes[lineStart...].firstIndex(of: 0x0A) ?? bytes.count
            var content = bytes[lineStart..<lineEnd]
            if content.last == 0x0D { content = content.dropLast() }
            defer { lineStart = lineEnd + 1; line += 1 }
            if content.isEmpty { continue }
            if comments && content.first == 0x23 {          // '#'
                if content.elementsEqual("# no comment".utf8) { comments = false }
                continue
            }
            let fields = content.split(separator: 0x09, omittingEmptySubsequences: false)
            func field(_ index: Int?) -> String? {
                guard let index, index < fields.count, !fields[index].isEmpty else { return nil }
                return String(decoding: fields[index], as: UTF8.self)
            }
            guard let text = field(textColumn) else { continue }
            let used = [textColumn, codeColumn, weightColumn]
            let extra = fields.indices.filter { !used.contains($0) && !fields[$0].isEmpty }.count
            try body(Row(line: line, text: text, code: field(codeColumn), weight: field(weightColumn),
                         extraColumns: extra))
        }
    }
}

/// How librime reads a weight (EntryCollector::CreateEntry): std::stod on
/// the field, which takes the longest numeric prefix and ignores the rest.
public enum Weight {
    public enum Reading: Equatable {
        case number(Double)
        case prefix(Double)      // digits, then other characters ("45N"): the digits count
        case scaled              // "50%": relative to a preset vocabulary, which there is none of: 0
        case notANumber          // librime logs a warning and uses 0
    }

    public static func read(_ field: String) -> Reading {
        if field.hasSuffix("%") { return .scaled }
        let s = Array(field.utf8)
        var i = 0
        while i < s.count, s[i] == 0x20 || s[i] == 0x09 { i += 1 }
        let start = i
        if i < s.count, s[i] == 0x2B || s[i] == 0x2D { i += 1 }      // sign
        var digits = 0
        while i < s.count, (0x30...0x39).contains(s[i]) { i += 1; digits += 1 }
        if i < s.count, s[i] == 0x2E {                               // fraction
            i += 1
            while i < s.count, (0x30...0x39).contains(s[i]) { i += 1; digits += 1 }
        }
        guard digits > 0 else { return .notANumber }
        if i < s.count, s[i] == 0x65 || s[i] == 0x45 {                // exponent, if digits follow
            var j = i + 1
            if j < s.count, s[j] == 0x2B || s[j] == 0x2D { j += 1 }
            if j < s.count, (0x30...0x39).contains(s[j]) {
                while j < s.count, (0x30...0x39).contains(s[j]) { j += 1 }
                i = j
            }
        }
        let value = Double(String(decoding: s[start..<i], as: UTF8.self)) ?? 0
        return i == s.count ? .number(value) : .prefix(value)
    }
}
