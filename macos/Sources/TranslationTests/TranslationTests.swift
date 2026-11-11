import Foundation

@MainActor
private final class FakeLookup: CandidateLookupProvider {
    var glossaryCalls: [String] = []
    var translationCalls: [String] = []
    var entries: [String: String] = [:]
    var delay: UInt64 = 5_000_000
    var glossaryDelay: UInt64 = 0
    var needsLanguages = false

    func glossary(_ key: CandidateLookupKey) async -> String? {
        glossaryCalls.append(key.text)
        try? await Task.sleep(nanoseconds: glossaryDelay)
        return entries[key.text]
    }

    func cancelTranslation(in slot: Int) {}

    func translate(_ key: CandidateLookupKey, slot: Int) async -> MachineTranslation {
        translationCalls.append(key.text)
        try? await Task.sleep(nanoseconds: delay)
        if needsLanguages { return .needsLanguages }
        return .text("translated " + key.text)
    }
}

/// Completion is controlled explicitly, including providers that do not return
/// immediately when cancelled. This makes queue and privacy checks independent
/// of the system model's speed or language installation.
@MainActor
private final class HeldLookup: CandidateLookupProvider {
    struct Pending {
        let text: String
        let slot: Int
        let continuation: CheckedContinuation<MachineTranslation, Never>
    }
    var calls: [String] = []
    var pending: [Pending] = []
    var cancelled: [Int] = []
    var peakActive = 0
    var redraws = 0

    func glossary(_ key: CandidateLookupKey) async -> String? { nil }

    func translate(_ key: CandidateLookupKey, slot: Int) async -> MachineTranslation {
        calls.append(key.text)
        return await withCheckedContinuation { continuation in
            pending.append(Pending(text: key.text, slot: slot, continuation: continuation))
            peakActive = max(peakActive, pending.count)
        }
    }

    func cancelTranslation(in slot: Int) { cancelled.append(slot) }

    func finish(_ text: String, result: MachineTranslation? = nil) {
        guard let i = pending.firstIndex(where: { $0.text == text }) else { return }
        pending.remove(at: i).continuation.resume(returning: result ?? .text("translated " + text))
    }

    func finishAll() {
        let remaining = pending
        pending.removeAll()
        for item in remaining { item.continuation.resume(returning: .unavailable) }
    }
}

@main
@MainActor
private enum TranslationTests {
    static func main() async { exit(await run()) }

    static func until(attempts: Int = 200, _ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    static func run() async -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ description: String) {
            print(ok ? "ok    \(description)" : "FAIL  \(description)")
            if !ok { failures += 1 }
        }

        check(CandidateLanguage.of("电脑") == .chinese && CandidateLanguage.of("apple") == .english &&
              CandidateLanguage.of("我用GitHub") == .chinese && CandidateLanguage.of("123") == nil &&
              CandidateLanguage.of("me@example.com") == nil && CandidateLanguage.of("https://example.com") == nil,
              "classifies Chinese, English and mixed candidates without sending addresses")
        check(CandidateTranslations.supported == (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26),
              "the feature is available only on macOS 26 or newer")

        let backend = FakeLookup()
        var redraws = 0
        let service = CandidateTranslations(provider: backend, prefetchDelay: 0) { redraws += 1 }
        service.setPage(["电脑", "apple", "apple"], highlighted: 1, policy: .normal)
        let prefetched = await until { service.captions() == ["…", "translated apple", "translated apple"] }
        check(prefetched && backend.translationCalls == ["apple"] && redraws == 0,
              "prefetch translates only the highlight, deduplicates entries, and does not redraw until Option")
        let before = backend.translationCalls.count
        service.setTranslationHeld(true)
        let pageReady = await until { service.captions().first == "translated 电脑" }
        check(pageReady && backend.translationCalls.count == before + 1 && backend.translationCalls == ["apple", "电脑"],
              "holding Option reuses the prefetched highlight and translates the remaining page")
        check(service.replacements() == ["translated 电脑", "translated apple", "translated apple"],
              "a finished translation replaces the candidate")
        check(service.committedText(for: "电脑") == "translated 电脑" && service.committedText(for: "nope") == nil,
              "a selection commits only a finished translation")

        service.clear()
        backend.translationCalls.removeAll()
        backend.entries = ["电脑": "computer", "apple": "苹果"]
        service.setPage(["电脑", "apple", "unlisted"], highlighted: 0, policy: .normal)
        service.setTranslationHeld(true)
        let mapped = await until { service.captions() == ["computer", "苹果", "translated unlisted"] }
        check(mapped && backend.translationCalls == ["unlisted"] && service.committedText(for: "电脑") == "computer",
              "glossary matches win in both directions and only a miss reaches system translation")

        service.clear()
        backend.translationCalls.removeAll()
        backend.delay = 250_000_000
        service.setPage(["slow miss", "apple"], highlighted: 0, policy: .normal)
        let fastMatch = await until {
            backend.translationCalls.contains("slow miss") && service.captions() == ["…", "苹果"]
        }
        check(fastMatch, "a slow system fallback does not delay other glossary matches on the page")

        service.clear()
        backend.delay = 60_000_000
        service.setPage(["old"], highlighted: 0, policy: .normal)
        service.setTranslationHeld(true)
        let oldStarted = await until { backend.translationCalls.contains("old") }
        service.setPage(["new"], highlighted: 0, policy: .normal)
        let newFinished = await until { service.captions() == ["translated new"] }
        check(oldStarted && newFinished && !service.captions().contains("translated old") && redraws > 0,
              "a late answer from an old page cannot replace the new page")

        service.clear()
        backend.glossaryCalls.removeAll()
        backend.translationCalls.removeAll()
        backend.delay = 40_000_000
        service.setPage(["secret"], highlighted: 0, policy: .incognito)
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(backend.translationCalls.isEmpty, "incognito does not prefetch")
        service.setTranslationHeld(true)
        let secretStarted = await until { backend.translationCalls.contains("secret") }
        service.setTranslationHeld(false)
        service.setTranslationHeld(true)
        let retried = await until { backend.translationCalls.filter { $0 == "secret" }.count >= 2 &&
                                    service.captions() == ["translated secret"] }
        check(secretStarted && retried, "releasing Option discards incognito work and a new hold can retry it")
        service.setTranslationHeld(false)
        check(service.captions() == ["…"] && service.replacements() == [""] &&
              service.committedText(for: "secret") == nil,
              "incognito results are cleared on release, and a pending lookup keeps the candidate")

        service.clear()
        backend.glossaryCalls.removeAll()
        backend.translationCalls.removeAll()
        service.setPage(["secret"], highlighted: 0, policy: .disabled)
        service.setTranslationHeld(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(backend.translationCalls.isEmpty && service.captions().isEmpty,
              "secure and password-manager contexts do not send candidates to providers")

        service.clear()
        backend.delay = 5_000_000
        backend.needsLanguages = true
        backend.translationCalls.removeAll()
        service.setPage(["apple", "missing"], highlighted: 0, policy: .normal)
        service.setTranslationHeld(true)
        let entry = await until { service.captions() == ["苹果", "请下载翻译语言"] }
        check(entry && backend.translationCalls == ["missing"] && service.committedText(for: "apple") == "苹果" &&
              service.committedText(for: "missing") == nil,
              "glossary matches work without installed system languages; misses offer setup")

        service.clear()
        backend.translationCalls.removeAll()
        backend.glossaryCalls.removeAll()
        backend.glossaryDelay = 60_000_000
        service.setPage(["stale"], highlighted: 0, policy: .normal)
        let staleStarted = await until { backend.glossaryCalls.contains("stale") }
        service.setPage(["apple"], highlighted: 0, policy: .normal)
        let next = await until { service.captions() == ["苹果"] }
        check(staleStarted && next && !backend.translationCalls.contains("stale"),
              "an outdated glossary miss never starts a fallback lookup")
        service.clear()

        let lifetimeBackend = FakeLookup()
        lifetimeBackend.delay = 30_000_000
        var temporary: CandidateTranslations? = CandidateTranslations(provider: lifetimeBackend) {}
        weak let releasedService = temporary
        temporary?.setPage(["lifetime"], highlighted: 0, policy: .normal)
        let lifetimeStarted = await until { lifetimeBackend.translationCalls.contains("lifetime") }
        temporary?.clear()
        temporary = nil
        let released = await until { releasedService == nil }
        check(lifetimeStarted && released, "cleared lookup workers release the service after in-flight work ends")

        // Rapid typing only reads the glossary; Option bypasses the quiet period.
        let typing = FakeLookup()
        typing.entries = ["apple": "苹果"]
        let debounced = CandidateTranslations(provider: typing, prefetchDelay: 300_000_000) {}
        debounced.setPage(["first", "apple"], highlighted: 0, policy: .normal)
        let immediateGlossary = await until { debounced.captions().last == "苹果" }
        debounced.setPage(["second", "apple"], highlighted: 0, policy: .normal)
        try? await Task.sleep(nanoseconds: 30_000_000)
        check(immediateGlossary && typing.translationCalls.isEmpty,
              "glossary hits remain immediate while transient pages do not start system translation")
        debounced.setPage(["final", "other"], highlighted: 1, policy: .normal)
        let quietHighlight = await until { typing.translationCalls == ["other"] }
        check(quietHighlight && !typing.translationCalls.contains("first") && !typing.translationCalls.contains("second"),
              "only the latest highlighted candidate is prefetched after typing settles")
        debounced.setPage(["explicit", "remaining"], highlighted: 0, policy: .normal)
        debounced.setTranslationHeld(true)
        let explicitReady = await until(attempts: 30) {
            debounced.replacements() == ["translated explicit", "translated remaining"]
        }
        check(explicitReady,
              "Option bypasses the 300 ms debounce and translates the whole current page")
        debounced.clear()
        let callsAfterClear = typing.translationCalls.count
        debounced.setPage(["hidden"], highlighted: 0, policy: .normal)
        debounced.setPage([], highlighted: 0, policy: .normal)
        try? await Task.sleep(nanoseconds: 350_000_000)
        check(typing.translationCalls.count == callsAfterClear, "hiding the page cancels deferred prefetch")
        debounced.clear()

        let held = HeldLookup()
        let scheduled = CandidateTranslations(provider: held, prefetchDelay: 0) { held.redraws += 1 }
        scheduled.setPage(["old"], highlighted: 0, policy: .normal)
        let heldOld = await until { held.calls == ["old"] }
        scheduled.setPage(["new"], highlighted: 0, policy: .normal)
        scheduled.setTranslationHeld(true)
        let heldNew = await until { held.calls == ["old", "new"] }
        check(heldOld && heldNew && held.pending.count == 2,
              "the current page starts without waiting for an unfinished old translation")
        held.finish("new")
        let visibleNew = await until { scheduled.replacements() == ["translated new"] }
        let beforeOld = held.redraws
        held.finish("old")
        let cachedOld = await until { scheduled.committedText(for: "old") == "translated old" }
        check(visibleNew && cachedOld && scheduled.replacements() == ["translated new"] && held.redraws == beforeOld,
              "a successful old result is cached without repainting or replacing the current page")
        scheduled.setPage(["old"], highlighted: 0, policy: .normal)
        check(scheduled.replacements() == ["translated old"] && held.calls == ["old", "new"],
              "returning to an old page reuses its result without another system translation")
        scheduled.clear()

        held.calls.removeAll()
        scheduled.setPage(["one"], highlighted: 0, policy: .normal)
        scheduled.setTranslationHeld(true)
        let oneStarted = await until { held.calls == ["one"] }
        scheduled.setPage(["two"], highlighted: 0, policy: .normal)
        let twoStarted = await until { held.calls == ["one", "two"] }
        scheduled.setPage(["three"], highlighted: 0, policy: .normal)
        let cancellationRequested = await until { held.cancelled.count == 2 }
        check(oneStarted && twoStarted && cancellationRequested && held.calls == ["one", "two"] && held.peakActive == 2,
              "rapid page changes cancel obsolete work and never exceed two occupied translation slots")
        held.finish("one", result: .unavailable)
        let threeStarted = await until { held.calls == ["one", "two", "three"] }
        held.finish("three")
        let threeReady = await until { scheduled.replacements() == ["translated three"] }
        check(threeStarted && threeReady && held.peakActive == 2,
              "the latest page starts as soon as a cancelled slot returns")
        scheduled.clear()
        held.finishAll()

        held.calls.removeAll()
        scheduled.setPage(["sensitive"], highlighted: 0, policy: .normal)
        let sensitiveStarted = await until { held.calls == ["sensitive"] }
        scheduled.setPage(["sensitive"], highlighted: 0, policy: .disabled)
        held.finish("sensitive")
        // Re-entering normal mode must issue a new lookup even if the cancelled
        // provider returned a successful answer after the privacy boundary.
        scheduled.setPage(["sensitive"], highlighted: 0, policy: .normal)
        let sensitiveRetried = await until { held.calls == ["sensitive", "sensitive"] }
        check(sensitiveStarted && sensitiveRetried && scheduled.committedText(for: "sensitive") == nil,
              "secure mode invalidates late normal results, including when the same word becomes visible again")
        held.finish("sensitive")
        let freshSensitive = await until { scheduled.committedText(for: "sensitive") == "translated sensitive" }
        check(freshSensitive, "the fresh request can complete after an earlier privacy epoch was cancelled")
        scheduled.clear()
        held.finishAll()
        _ = await until { scheduled.committedText(for: "two") == nil }

        held.calls.removeAll()
        scheduled.setPage(["private"], highlighted: 0, policy: .incognito)
        scheduled.setTranslationHeld(true)
        let privateStarted = await until { held.calls == ["private"] }
        scheduled.setTranslationHeld(false)
        scheduled.setPage(["public"], highlighted: 0, policy: .normal)
        held.finish("private")
        let publicStarted = await until { held.calls.contains("public") }
        held.finish("public")
        let publicReady = await until { scheduled.committedText(for: "public") == "translated public" }
        check(privateStarted && publicStarted && publicReady && scheduled.committedText(for: "private") == nil,
              "a late incognito result cannot populate the normal cache after release or a policy change")
        scheduled.clear()
        held.finishAll()

        if #available(macOS 26.0, *) {
            let index = URL(fileURLWithPath: "build/glossary.sqlite3")
            let actual = SystemCandidateLookup(glossaryURL: index)
            let computer = await actual.glossary(CandidateLookupKey(text: "电脑", language: .chinese))
            let greeting = await actual.glossary(CandidateLookupKey(text: "你好", language: .chinese))
            let apple = await actual.glossary(CandidateLookupKey(text: "APPLE", language: .english))
            let hello = await actual.glossary(CandidateLookupKey(text: "hello", language: .english))
            let missing = await actual.glossary(CandidateLookupKey(text: "not-a-real-glossary-entry-123", language: .english))
            check(computer == "computer" && greeting == "hello; hi" && apple == "苹果" && hello == "你好" && missing == nil,
                  "the bundled TSV index supports both directions, case, alternatives and misses")
            let absent = SystemCandidateLookup(glossaryURL: URL(fileURLWithPath: "/no/such/glossary.sqlite3"))
            let unavailableIndex = await absent.glossary(CandidateLookupKey(text: "电脑", language: .chinese))
            check(unavailableIndex == nil, "a missing glossary index safely falls back to system translation")
        }
        return failures == 0 ? 0 : 1
    }
}
