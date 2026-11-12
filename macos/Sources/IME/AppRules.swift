import AppKit

/// The apps the user added, and the input rules for each.
/// Typing reads the in-memory sets only: no disk, and no look-up of installed apps.
@MainActor
enum AppRules {
    struct Entry: Identifiable, Equatable {
        static let followDefault = "跟随默认"
        static let halfwidth = "始终使用半角标点"

        var id: String
        var name: String
        var halfwidthPunctuation: Bool
        var noLearn: Bool

        var punctuationTitle: String { halfwidthPunctuation ? Self.halfwidth : Self.followDefault }
        var statusTitle: String { noLearn ? "\(punctuationTitle), 不学习" : punctuationTitle }
    }

    private static let storageKey = "appRules"
    private static var rows: [[String: Any]] = []
    private static var halfwidthIDs = Set<String>()
    private static var noLearnIDs = Set<String>()

    static func halfwidthPunctuation(for bundleID: String) -> Bool {
        !bundleID.isEmpty && halfwidthIDs.contains(bundleID)
    }

    static func noLearn(for bundleID: String) -> Bool {
        !bundleID.isEmpty && noLearnIDs.contains(bundleID)
    }

    static var entries: [Entry] {
        rows.compactMap { row in
            guard let id = row["id"] as? String else { return nil }
            return Entry(id: id, name: row["name"] as? String ?? id,
                         halfwidthPunctuation: halfwidthIDs.contains(id), noLearn: noLearnIDs.contains(id))
        }
    }

    static func reload() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            rows = []
            halfwidthIDs = []
            noLearnIDs = []
            return
        }
        rows = AppRulesDocument.decode(data)
        rebuild()
    }

    static func upsert(id: String, name: String) {
        rows = AppRulesDocument.upsert(rows, id: id, name: name)
        store()
    }

    static func setHalfwidth(_ on: Bool, for id: String) {
        rows = AppRulesDocument.setHalfwidth(rows, id: id, on: on)
        store()
    }

    static func setNoLearn(_ on: Bool, for id: String) {
        rows = AppRulesDocument.setNoLearn(rows, id: id, on: on)
        store()
    }

    static func remove(_ id: String) {
        rows = AppRulesDocument.remove(rows, id: id)
        store()
    }

    /// The icon Launch Services has for this bundle, or the generic application icon.
    static func icon(for bundleID: String, side: CGFloat) -> NSImage {
        let source: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            source = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            source = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        }
        let image = (source.copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: side, height: side)
        return image
    }

    private static func store() {
        rebuild()
        if let data = AppRulesDocument.encode(rows) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    private static func rebuild() {
        halfwidthIDs = []
        noLearnIDs = []
        for row in rows {
            guard let id = row["id"] as? String else { continue }
            if AppRulesDocument.isHalfwidth(row) { halfwidthIDs.insert(id) }
            if AppRulesDocument.isNoLearn(row) { noLearnIDs.insert(id) }
        }
    }
}
