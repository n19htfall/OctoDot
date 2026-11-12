import Foundation

/// Per-app input rules, indexed by bundle id. A record can hold later input
/// options beside `punctuation`; a missing punctuation field follows the default.
enum AppRulesDocument {
    static let halfwidthPunctuation = "halfwidth"

    static func isHalfwidth(_ record: [String: Any]) -> Bool {
        record["punctuation"] as? String == halfwidthPunctuation
    }

    /// Missing, or anything other than true, leaves learning on.
    static func isNoLearn(_ record: [String: Any]) -> Bool {
        record["noLearn"] as? Bool == true
    }

    /// A bundle id: letters, digits, dots and hyphens, with a dot. Anything else is refused.
    static func bundleID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count >= 3, id.count <= 255, id.contains("."), let first = id.first, first.isLetter else { return nil }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
        guard id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return id
    }

    /// The name shown in the list. The rule itself is the bundle id.
    static func displayName(_ raw: String, id: String) -> String {
        let folded = raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = folded.lowercased().hasSuffix(".app")
            ? String(folded.dropLast(4)).trimmingCharacters(in: .whitespacesAndNewlines) : folded
        if stripped.isEmpty { return id }
        if stripped.count > 256 { return String(stripped.prefix(256)) }
        return stripped
    }

    /// Drops records without a bundle id. The first record for an id wins.
    static func normalized(_ rows: [[String: Any]]) -> [[String: Any]] {
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for row in rows {
            guard let raw = row["id"] as? String, let id = bundleID(raw), seen.insert(id).inserted else { continue }
            var copy = row
            copy["id"] = id
            copy["name"] = displayName(row["name"] as? String ?? "", id: id)
            out.append(copy)
        }
        return out
    }

    static func upsert(_ rows: [[String: Any]], id: String, name: String) -> [[String: Any]] {
        guard let id = bundleID(id) else { return normalized(rows) }
        var rows = normalized(rows)
        let shown = displayName(name, id: id)
        if let index = rows.firstIndex(where: { $0["id"] as? String == id }) {
            rows[index]["name"] = shown
            return rows
        }
        rows.append(["id": id, "name": shown])
        return rows
    }

    static func setHalfwidth(_ rows: [[String: Any]], id: String, on: Bool) -> [[String: Any]] {
        guard let id = bundleID(id) else { return normalized(rows) }
        var rows = normalized(rows)
        guard let index = rows.firstIndex(where: { $0["id"] as? String == id }) else { return rows }
        if on { rows[index]["punctuation"] = halfwidthPunctuation }
        else { rows[index].removeValue(forKey: "punctuation") }
        return rows
    }

    static func setNoLearn(_ rows: [[String: Any]], id: String, on: Bool) -> [[String: Any]] {
        guard let id = bundleID(id) else { return normalized(rows) }
        var rows = normalized(rows)
        guard let index = rows.firstIndex(where: { $0["id"] as? String == id }) else { return rows }
        if on { rows[index]["noLearn"] = true }
        else { rows[index].removeValue(forKey: "noLearn") }
        return rows
    }

    static func remove(_ rows: [[String: Any]], id: String) -> [[String: Any]] {
        guard let id = bundleID(id) else { return normalized(rows) }
        return normalized(rows).filter { ($0["id"] as? String) != id }
    }

    static func encode(_ rows: [[String: Any]]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: normalized(rows), format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> [[String: Any]] {
        guard let rows = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [[String: Any]]
        else { return [] }
        return normalized(rows)
    }
}

/// The app the companion's file panel picked: its bundle id and display name,
/// and nothing else. No path and no bookmark, so the access ends with the panel.
enum AppPick {
    struct Choice: Equatable {
        var id: String
        var name: String
    }

    static var pending: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identity.appGroup)?
            .appendingPathComponent("app-pick.plist")
    }

    static func encode(id: String, name: String) -> Data? {
        guard let id = AppRulesDocument.bundleID(id) else { return nil }
        let object = ["id": id, "name": AppRulesDocument.displayName(name, id: id)]
        return try? PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
    }

    static func decode(_ data: Data) -> Choice? {
        guard data.count < 4096,
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              object.keys.allSatisfy({ $0 == "id" || $0 == "name" }),
              let raw = object["id"] as? String, let id = AppRulesDocument.bundleID(raw) else { return nil }
        return Choice(id: id, name: AppRulesDocument.displayName(object["name"] as? String ?? "", id: id))
    }

    @discardableResult
    static func write(_ choice: Choice) -> Bool {
        guard let url = pending, let data = encode(id: choice.id, name: choice.name) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    /// Reads the hand-off and deletes it. A second call, or a cancel, finds nothing.
    static func take() -> Choice? {
        guard let url = pending, let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return decode(data)
    }

    static func discard() {
        guard let url = pending else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
