import Foundation

@MainActor
private final class FakeCore: ReloadableGeneration {
    let name: String
    var starts: [Int32]
    var ready = true
    var mayStop = true
    var active = false
    var directories: [String] = []
    var stops = 0
    init(_ name: String, _ starts: [Int32] = [0]) { self.name = name; self.starts = starts }
    func start(dataDirectory: String) -> Int32 {
        directories.append(dataDirectory)
        let status = starts.count > 1 ? starts.removeFirst() : starts[0]
        active = status == 0
        return status
    }
    func readyForReload() -> Bool { ready }
    func stopForReload() -> Bool {
        stops += 1
        guard mayStop else { return false }
        active = false
        return true
    }
    func discard() { active = false }
}

@main
@MainActor
private enum ReloadTests {
    static func main() { exit(run()) }

    static func run() -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ description: String) {
            print(ok ? "ok    \(description)" : "FAIL  \(description)")
            if !ok { failures += 1 }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("octodot-reload-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("installed-data")
        try! fm.createDirectory(at: source, withIntermediateDirectories: true)
        let image = source.appendingPathComponent("lexicon.img")
        try! Data("old image".utf8).write(to: image)
        let saved = try! GenerationData.snapshot(from: source, in: root.appendingPathComponent("old"))
        try! Data("new image".utf8).write(to: image)
        check((try? Data(contentsOf: saved.appendingPathComponent("lexicon.img"))) == Data("old image".utf8),
              "a retained generation keeps its original data when the installed bundle changes")
        let incomplete = root.appendingPathComponent("incomplete")
        do {
            _ = try GenerationData.snapshot(from: root.appendingPathComponent("missing"), in: incomplete)
            check(false, "a failed data snapshot is rejected")
        } catch {
            check(!fm.fileExists(atPath: incomplete.path), "a failed data snapshot removes its partial directory")
        }

        let old = FakeCore("old")
        let broken = FakeCore("broken", [7, 0])
        var busy = false
        var retired = 0
        var copies = 0
        var removed: [String] = []
        var published: String?
        var snapshotAvailable = true
        let switcher = ReloadCoordinator<FakeCore>(
            open: { name in name == "old" ? old : name == "broken" ? broken : nil },
            snapshot: {
                guard snapshotAvailable else { return nil }
                copies += 1
                return "data-\(copies)"
            },
            removeSnapshot: { removed.append($0) },
            canRetire: { !busy },
            retire: { retired += 1 },
            publish: { published = $0?.name })

        check(switcher.reload("old") == .active && published == "old" && old.active,
              "initial activation is acknowledged only after start")
        busy = true
        check(switcher.reload("broken") == .deferred && old.active && retired == 0 && copies == 1,
              "an active composition defers the switch without retiring its handler")
        busy = false
        old.ready = false
        check(switcher.reload("broken") == .deferred && old.active && retired == 0,
              "a running worker defers the switch")
        old.ready = true
        snapshotAvailable = false
        check(switcher.reload("broken") == .failed && old.active && published == "old" && retired == 0,
              "failure to retain candidate data leaves the old core running")
        snapshotAvailable = true
        check(switcher.reload("broken") == .failed && published == "old" && old.active && !broken.active &&
              switcher.current?.name == "old" && old.directories == ["data-1", "data-1"] && removed == ["data-2"],
              "failed startup restores and reports the old core using its own retained data")
        check(switcher.reload("broken") == .active && published == "broken" && broken.active && !old.active &&
              switcher.current?.dataDirectory == "data-3" && removed.contains("data-1"),
              "a retry activates the candidate and releases the previous data")
        let after = copies
        check(switcher.reload("broken") == .active && copies == after,
              "an already active generation is acknowledged without another restart")
        switcher.stop()
        check(!broken.active && published == nil && removed.contains("data-3"), "shutdown releases the active generation")

        let first = FakeCore("first", [0, 1, 0])
        let bad = FakeCore("bad", [1])
        var number = 0
        var actual: String?
        let retry = ReloadCoordinator<FakeCore>(
            open: { $0 == "first" ? first : bad }, snapshot: { number += 1; return "copy-\(number)" },
            removeSnapshot: { _ in }, canRetire: { true }, retire: {}, publish: { actual = $0?.name })
        check(retry.reload("first") == .active, "rollback test starts the first generation")
        check(retry.reload("bad") == .failed && retry.current == nil && actual == nil,
              "a failed rollback is not reported as a working core")
        check(retry.reload("bad") == .failed && retry.current?.name == "first" && actual == "first" && first.active,
              "a later retry can recover the retained fallback")
        retry.stop()

        let unsaved = FakeCore("unsaved")
        let next = FakeCore("next")
        var activeName: String?
        let blockedSave = ReloadCoordinator<FakeCore>(
            open: { $0 == "unsaved" ? unsaved : next }, snapshot: { "saved-data" },
            removeSnapshot: { _ in }, canRetire: { true }, retire: {}, publish: { activeName = $0?.name })
        check(blockedSave.reload("unsaved") == .active, "save failure test starts a core")
        unsaved.mayStop = false
        check(blockedSave.reload("next") == .failed && unsaved.active && !next.active && activeName == "unsaved",
              "a failed stop leaves the old generation selected for a later retry")
        blockedSave.stop()
        return failures == 0 ? 0 : 1
    }
}
