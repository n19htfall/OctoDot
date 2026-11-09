import Foundation

/// Drives the same Engine bridge the IME uses, without IMK, so the Swift ↔
/// Goose path can be tested and timed from the command line.
///
///   octo-smoke             functional checks, then key-to-snapshot latency
///   octo-smoke --crash=X   crash on purpose after goose_init (crash-tests.sh):
///     host-segv       a bad store in Swift code: Goose's SIGSEGV handler must
///                     pass it on, so macOS writes a normal crash report
///     goose-oob       a failed bounds check inside the engine
///     host-overflow   unbounded recursion in Swift on the goose_init thread
@main
@MainActor
enum Smoke {
    static func main() {
        let engine = Engine.shared
        engine.start()
        if let mode = CommandLine.arguments.first(where: { $0.hasPrefix("--crash=") }) {
            crash(String(mode.dropFirst("--crash=".count)))
        }
        let failures = functionalChecks(engine)
        latency(engine)
        exit(failures == 0 ? 0 : 1)
    }

    private static func functionalChecks(_ engine: Engine) -> Int {
        var failures = 0
        func check(_ condition: Bool, _ what: String) {
            print(condition ? "ok    \(what)" : "FAIL  \(what)")
            if !condition { failures += 1 }
        }
        func letter(_ c: Character) -> TranslatedKey {
            TranslatedKey(key: .other, codepoint: c.unicodeScalars.first!.value, modifiers: [])
        }
        let space = TranslatedKey(key: .space, codepoint: 32, modifiers: [])
        let session = engine.newSession(clientBundleID: "com.apple.TextEdit")
        func type(_ text: String) { for c in text { _ = engine.process(session, letter(c)) } }

        type("nihao")
        let snap = engine.snapshot(session)
        check(snap.isComposing && snap.preedit == "nihao" && snap.caretUTF8 == 5, "preedit shows the letters")
        check(snap.candidates.first == "你好", "the phrase is the first candidate")
        var (result, after) = engine.process(session, space)
        check(result.contains(.hasCommit) && after?.commit == "你好", "space commits the first candidate")
        check(after?.isComposing == false && after?.candidates.isEmpty == true, "commit clears the composition")

        type("zhong")
        check(engine.snapshot(session).candidates == ["中", "种", "重", "众", "中文"],
              "exact matches first, then completions")
        (result, after) = engine.process(session, letter("3"))
        check(after?.commit == "重", "a digit selects that candidate")

        type("wenx")
        (result, _) = engine.process(session, TranslatedKey(key: .backspace, codepoint: 8, modifiers: []))
        check(engine.snapshot(session).preedit == "wen", "backspace deletes one letter")
        (result, _) = engine.process(session, TranslatedKey(key: .escape, codepoint: 27, modifiers: []))
        check(!engine.snapshot(session).isComposing, "escape cancels")

        (result, _) = engine.process(session, letter("x").with(modifiers: .command))
        check(!result.contains(.handled), "Command shortcuts pass through to the app")
        (result, _) = engine.process(session, letter("1"))
        check(!result.contains(.handled), "keys pass through when not composing")

        type(String(repeating: "a", count: 40))
        check(engine.snapshot(session).preedit.count == 32, "a full input buffer swallows keys, never aborts")
        _ = engine.process(session, TranslatedKey(key: .escape, codepoint: 27, modifiers: []))

        let other = engine.newSession(clientBundleID: "com.example.other")
        type("ni")
        check(engine.snapshot(other).preedit.isEmpty, "a session sees only its own composition")
        engine.free(session)
        (result, _) = engine.process(session, letter("a"))
        check(result.isEmpty, "a freed session's handle is refused, not reused")
        let reused = engine.newSession(clientBundleID: "com.example.reuse")
        (result, _) = engine.process(session, letter("a"))
        check(result.isEmpty, "a stale handle stays refused after its slot is reused")
        _ = engine.process(reused, letter("n"))
        check(engine.snapshot(reused).preedit == "n", "the session in the reused slot works")
        return failures
    }

    private static func latency(_ engine: Engine) {
        let session = engine.newSession(clientBundleID: "bench")
        let keys = "zhongwen".unicodeScalars.map {
            TranslatedKey(key: .other, codepoint: $0.value, modifiers: [])
        } + [TranslatedKey(key: .space, codepoint: 32, modifiers: [])]
        var samples: [UInt64] = []
        samples.reserveCapacity(20_000 * keys.count)
        for _ in 0..<20_000 {
            for key in keys {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let (_, snapshot) = engine.process(session, key)
                withExtendedLifetime(snapshot) {}
                samples.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
            }
        }
        samples.sort()
        func percentile(_ p: Double) -> UInt64 { samples[min(samples.count - 1, Int(Double(samples.count) * p))] }
        print("latency  key → engine → snapshot decoded, \(samples.count) keys: " +
              "p50 \(percentile(0.50)) ns, p99 \(percentile(0.99)) ns, max \(samples.last!) ns")
    }

    private static func crash(_ mode: String) -> Never {
        switch mode {
        case "host-segv":
            UnsafeMutablePointer<Int>(bitPattern: 0x10)!.pointee = 1
        case "goose-oob":
            _ = octo_debug_oob(1000)
        case "host-overflow":
            _ = recurse(0)
        default:
            break
        }
        print("crash mode \(mode) did not crash")
        exit(3)
    }

    @inline(never)
    private static func recurse(_ depth: Int) -> Int {
        var frame = [depth, depth]
        frame.withUnsafeMutableBufferPointer { _ in }
        return recurse(depth + 1) + frame[0]
    }
}

extension TranslatedKey {
    func with(modifiers: Engine.Modifiers) -> TranslatedKey {
        var copy = self
        copy.modifiers = modifiers
        return copy
    }
}
