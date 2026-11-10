import Foundation

enum GenerationData {
    /// Make a separate directory before retiring the current core. If the
    /// copy fails, remove its incomplete parent and leave the core alone.
    static func snapshot(from source: URL, in parent: URL) throws -> URL {
        let fm = FileManager.default
        let destination = parent.appendingPathComponent("data", isDirectory: true)
        do {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? fm.removeItem(at: parent)
            throw error
        }
    }
}

/// The engine runtime can host only one generation at a time. Its data must
/// outlive the bundle swap so that a stopped generation can be started again.
@MainActor
protocol ReloadableGeneration: AnyObject {
    func start(dataDirectory: String) -> Int32
    func readyForReload() -> Bool
    func stopForReload() -> Bool
    func discard()
}

@MainActor
final class ReloadCoordinator<Core: ReloadableGeneration> {
    struct Generation {
        let name: String
        let core: Core
        let dataDirectory: String
    }

    enum Result { case active, deferred, failed }

    private(set) var current: Generation?
    // If even rollback fails, retain the previous generation for another try.
    private var fallback: Generation?
    private let open: (String) -> Core?
    private let snapshot: () -> String?
    private let removeSnapshot: (String) -> Void
    private let canRetire: () -> Bool
    private let retire: () -> Void
    private let publish: (Generation?) -> Void

    init(open: @escaping (String) -> Core?, snapshot: @escaping () -> String?,
         removeSnapshot: @escaping (String) -> Void, canRetire: @escaping () -> Bool,
         retire: @escaping () -> Void, publish: @escaping (Generation?) -> Void) {
        self.open = open
        self.snapshot = snapshot
        self.removeSnapshot = removeSnapshot
        self.canRetire = canRetire
        self.retire = retire
        self.publish = publish
    }

    func reload(_ name: String) -> Result {
        if current?.name == name { return .active }
        if let current, (!canRetire() || !current.core.readyForReload()) { return .deferred }
        guard let next = open(name), let directory = snapshot() else { return .failed }
        let previous = current ?? fallback
        if let current {
            retire()
            guard current.core.stopForReload() else {
                removeSnapshot(directory)
                return .failed
            }
            self.current = nil
        }
        if next.start(dataDirectory: directory) == 0 {
            current = Generation(name: name, core: next, dataDirectory: directory)
            fallback = nil
            publish(current)
            if let previous { removeSnapshot(previous.dataDirectory) }
            return .active
        }
        next.discard()
        removeSnapshot(directory)
        if let previous {
            if previous.core.start(dataDirectory: previous.dataDirectory) == 0 {
                current = previous
                fallback = nil
                publish(current)
            } else {
                previous.core.discard()
                fallback = previous
                publish(nil)
            }
        } else {
            publish(nil)
        }
        return .failed
    }

    func stop() {
        retire()
        current?.core.discard()
        if let current { removeSnapshot(current.dataDirectory) }
        if let fallback { removeSnapshot(fallback.dataDirectory) }
        current = nil
        fallback = nil
        publish(nil)
    }
}
