import CryptoKit
import Foundation

/// The grammar model in the folder shared with the input method (GrammarPin;
/// docs/distribution-and-onboarding.md, section 5). The disk image's
/// OctoDot.app carries a copy (Contents/Resources/Grammar), which an install
/// puts there; an update's OctoDot.app carries none, so an update brings the
/// 400 MB only when data/grammar.lock changed, downloaded then from a release
/// of its own. Either way the model goes in only with the SHA-256 that the
/// input method's signed bundle pins, and through a staging folder renamed
/// into place, so the input method never maps half a file.
enum GrammarStore {
    enum Failure: Error, CustomStringConvertible {
        case noPin, noSharedFolder, wrongSize, wrongHash

        var description: String {
            switch self {
            case .noPin: "随附的输入法没有指定语法模型"
            case .noSharedFolder: "与输入法共享的文件夹不存在"
            case .wrongSize, .wrongHash: "文件不是输入法所需要的模型"
            }
        }
    }

    /// The model the input method inside this app wants.
    static var pin: GrammarPin? {
        GrammarPin(ime: Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/OctoDotIME.app"))
    }

    /// This app's own copy of it: the disk image's app has one, an update's none.
    static func bundledCopy(of pin: GrammarPin) -> URL? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Grammar/\(pin.name)"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// Whether the shared folder lacks the model the input method wants.
    static var isMissing: Bool { pin.map { !$0.isInstalled } ?? false }

    /// Puts the model in the shared folder unless it is there: copied from
    /// this app (a clone, on APFS), else downloaded, `progress` getting the
    /// share downloaded. True if it put one there.
    @discardableResult
    static func ensure(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> Bool {
        try Task.checkCancellation()
        guard let pin else { throw Failure.noPin }
        guard !pin.isInstalled else { return false }
        guard let root = GrammarPin.root, let folder = pin.folder else { throw Failure.noSharedFolder }
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = staging.appendingPathComponent(pin.name)
        if let copy = bundledCopy(of: pin) {
            try await Task.detached { try FileManager.default.copyItem(at: copy, to: staged) }.value
        } else {
            guard let url = pin.url else { throw Failure.noPin }
            let file = try await ProgressDownload.fetch(url, configuration: UpdateProxyConfiguration.ephemeral()) {
                written, expected in
                let total = expected > 0 ? Double(expected) : Double(pin.size)
                progress(min(1, Double(written) / max(total, 1)))
            }
            do { try fm.moveItem(at: file, to: staged) } catch {
                try? fm.removeItem(at: file)
                throw error
            }
        }
        try Task.checkCancellation()
        let size = (try? fm.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.uint64Value
        guard size == pin.size else { throw Failure.wrongSize }
        let hashing = Task.detached { try sha256(of: staged) }
        let hash = try await withTaskCancellationHandler {
            try await hashing.value
        } onCancel: {
            hashing.cancel()
        }
        guard hash == pin.sha256 else { throw Failure.wrongHash }
        try Task.checkCancellation()
        try? fm.removeItem(at: folder)                  // what an interrupted attempt left
        try fm.moveItem(at: staging, to: folder)
        return true
    }

    /// Removes every model but the one the installed input method wants, and
    /// whatever an interrupted attempt left. After an install, never before:
    /// until then the input method in use may want another.
    static func prune() {
        guard let pin, let root = GrammarPin.root,
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        else { return }
        for item in items where item.lastPathComponent != pin.sha256 { try? FileManager.default.removeItem(at: item) }
    }

    /// Removes the models (uninstalling: they are not the user's data).
    static func removeAll() {
        if let root = GrammarPin.root { try? FileManager.default.removeItem(at: root) }
    }

    private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            try Task.checkCancellation()
            let more = try autoreleasepool { () -> Bool in
                guard let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty else { return false }
                hasher.update(data: chunk)
                return true
            }
            if !more { break }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
