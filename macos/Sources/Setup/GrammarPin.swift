import Foundation

/// 万象's grammar model: 400 MB that changes only with data/grammar.lock. It
/// lives outside the bundles (docs/distribution-and-onboarding.md, section 5),
/// so an update that does not change it does not carry it: in the App Group
/// folder the input method reads and the companion fills,
///
///   <group>/Grammar/<sha256>/<name>.gram
///
/// one folder per model, so a new one can arrive beside the one in use. The
/// input method's signed bundle names the model it wants in
/// data/grammar.pin, one line "sha256 size name", written from
/// data/grammar.lock when it is built; nothing goes into the folder without
/// that SHA-256.
struct GrammarPin: Equatable, Sendable {
    var sha256: String      // lowercase hex
    var size: UInt64
    var name: String        // the file's name, which grammar.img records

    init?(_ text: String) {
        let fields = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 3, fields[0].count == 64, fields[0].allSatisfy(\.isHexDigit),
              let size = UInt64(fields[1]), size > 0,
              fields[2].hasSuffix(".gram"), !fields[2].contains("/"), !fields[2].hasPrefix(".") else { return nil }
        sha256 = fields[0].lowercased()
        self.size = size
        name = fields[2]
    }

    init?(contentsOf file: URL) {
        guard let data = try? Data(contentsOf: file), data.count < 1024 else { return nil }
        self.init(String(decoding: data, as: UTF8.self))
    }

    /// The pin inside an input method bundle.
    init?(ime bundle: URL) {
        self.init(contentsOf: bundle.appendingPathComponent("Contents/Resources/data/grammar.pin"))
    }

    /// The shared folder's Grammar folder; nil outside a process with the App Group.
    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identity.appGroup)?
            .appendingPathComponent("Grammar", isDirectory: true)
    }

    var folder: URL? { Self.root?.appendingPathComponent(sha256, isDirectory: true) }
    var file: URL? { folder?.appendingPathComponent(name) }

    /// Whether the shared folder holds it. By size: the companion checked
    /// its hash before it put it there, and the engine checks the size again.
    var isInstalled: Bool {
        guard let path = file?.path, let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let bytes = (attributes[.size] as? NSNumber)?.uint64Value else { return false }
        return bytes == size
    }

    /// Where a release publishes it: a release of its own, tagged by its
    /// hash, made only when data/grammar.lock changes (make grammar-release).
    var url: URL? { URL(string: Identity.releasesPrefix + "grammar-\(sha256.prefix(12))/\(name)") }
}
