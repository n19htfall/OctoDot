import Foundation

@MainActor
private final class FakeLookup: CandidateLookupProvider {
    var dictionaryCalls: [String] = []
    var translationCalls: [String] = []
    var delay: UInt64 = 5_000_000
    var needsLanguages = false

    func dictionary(_ text: String) async -> String? {
        dictionaryCalls.append(text)
        try? await Task.sleep(nanoseconds: delay)
        return "entry " + text
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
              "a selection commits only a finished machine translation")

        backend.delay = 60_000_000
        service.setPage(["old"], highlighted: 0, policy: .normal)
        let oldStarted = await until { backend.translationCalls.contains("old") }
        service.setPage(["new"], highlighted: 0, policy: .normal)
        let newFinished = await until { service.captions() == ["translated new"] }
        check(oldStarted && newFinished && !service.captions().contains("translated old") && redraws > 0,
              "a late answer from an old page cannot replace the new page")

        service.clear()
        backend.dictionaryCalls.removeAll()
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
        backend.dictionaryCalls.removeAll()
        backend.translationCalls.removeAll()
        service.setPage(["secret"], highlighted: 0, policy: .disabled)
        service.setOptionDown(true)
        try? await Task.sleep(nanoseconds: 50_000_000)
        check(backend.translationCalls.isEmpty && service.captions().isEmpty,
              "secure and password-manager contexts do not send candidates to providers")

        service.clear()
        backend.delay = 5_000_000
        backend.needsLanguages = true
        service.setPage(["hello"], highlighted: 0, policy: .normal)
        let entry = await until { service.captions() == ["词典: entry hello"] }
        check(entry && service.committedText(for: "hello") == nil,
              "an unstructured dictionary result is labeled as an entry, not a translation")
        service.clear()
        return failures == 0 ? 0 : 1
    }
}
