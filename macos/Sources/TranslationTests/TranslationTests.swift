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

    func translate(_ key: CandidateLookupKey) async -> MachineTranslation {
        translationCalls.append(key.text)
        try? await Task.sleep(nanoseconds: delay)
        if needsLanguages { return .needsLanguages }
        return .text("translated " + key.text)
    }
}

@main
@MainActor
private enum TranslationTests {
    static func main() async { exit(await run()) }

    static func until(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
        for _ in 0..<200 {
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
        let service = CandidateTranslations(provider: backend) { redraws += 1 }
        service.setPage(["电脑", "apple", "apple"], highlighted: 1, policy: .normal)
        let prefetched = await until { service.captions() == ["translated 电脑", "translated apple", "translated apple"] }
        check(prefetched && backend.translationCalls == ["apple", "电脑"] && redraws == 0,
              "prefetch starts with the highlight, deduplicates entries, and does not redraw until Option")
        let before = backend.translationCalls.count
        service.setOptionDown(true)
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(service.captions().first == "translated 电脑" && backend.translationCalls.count == before,
              "holding Option uses prefetched results")
        check(service.replacements() == ["translated 电脑", "translated apple", "translated apple"],
              "a finished translation replaces the candidate")
        check(service.committedText(for: "电脑") == "translated 电脑" && service.committedText(for: "nope") == nil,
              "a selection commits only a finished translation")

        service.clear()
        backend.translationCalls.removeAll()
        backend.entries = ["电脑": "computer", "apple": "苹果"]
        service.setPage(["电脑", "apple", "unlisted"], highlighted: 0, policy: .normal)
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
        service.setOptionDown(true)
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
        service.setOptionDown(true)
        let secretStarted = await until { backend.translationCalls.contains("secret") }
        service.setOptionDown(false)
        service.setOptionDown(true)
        let retried = await until { backend.translationCalls.filter { $0 == "secret" }.count >= 2 &&
                                    service.captions() == ["translated secret"] }
        check(secretStarted && retried, "releasing Option discards incognito work and a new hold can retry it")
        service.setOptionDown(false)
        check(service.captions() == ["…"] && service.replacements() == [""] &&
              service.committedText(for: "secret") == nil,
              "incognito results are cleared on release, and a pending lookup keeps the candidate")

        service.clear()
        backend.glossaryCalls.removeAll()
        backend.translationCalls.removeAll()
        service.setPage(["secret"], highlighted: 0, policy: .disabled)
        service.setOptionDown(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(backend.translationCalls.isEmpty && service.captions().isEmpty,
              "secure and password-manager contexts do not send candidates to providers")

        service.clear()
        backend.delay = 5_000_000
        backend.needsLanguages = true
        backend.translationCalls.removeAll()
        service.setPage(["apple", "missing"], highlighted: 0, policy: .normal)
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
