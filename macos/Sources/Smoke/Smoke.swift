import Foundation

/// Drives the Engine bridge the IME uses, without IMK, against the real
/// images: what typing gives through Swift, and how long a key takes there.
///
///   octo-smoke DATA_DIRECTORY
@main
@MainActor
enum Smoke {
    static func main() {
        exit(run())
    }

    // Return normally so the test's local values and deferred temporary-file
    // cleanup are released before main exits (and leak tools inspect it).
    static func run() -> Int32 {
        guard CommandLine.arguments.count == 2 else {
            print("usage: octo-smoke DATA_DIRECTORY")
            return 2
        }
        let engine = Engine.shared
        let status = engine.start(dataDirectory: CommandLine.arguments[1])
        var failures = 0
        func check(_ condition: Bool, _ what: String) {
            print(condition ? "ok    \(what)" : "FAIL  \(what)")
            if !condition { failures += 1 }
        }
        check(status == 0, "the engine opens the images (status \(status))")

        let session = engine.newSession(clientBundleID: "com.apple.TextEdit")
        func type(_ text: String) -> Snapshot {
            var last = Snapshot.empty
            for c in text { if let snapshot = engine.process(session, .character(c)).1 { last = snapshot } }
            return last
        }

        var snapshot = type("zhongguoren")
        check(snapshot.isComposing && snapshot.preedit == "zhong guo ren", "the preedit shows the letters, by syllable")
        check(snapshot.candidates.first?.text == "中国人", "中国人 is the first candidate")
        check(snapshot.candidates.count == 6 && snapshot.hasNextPage && !snapshot.hasPreviousPage,
              "a page holds six candidates, with more after")
        var (result, after) = engine.process(session, .special(.space))
        check(result.contains(.hasCommit) && after?.commit == "中国人" && after?.isComposing == false &&
              after?.preedit.isEmpty == true, "space commits it and ends the composition, leaving no preedit")
        snapshot = type("github")
        check(snapshot.candidates.first?.text == "GitHub", "github offers GitHub first: those letters have no Chinese reading")
        _ = engine.process(session, .special(.escape))
        engine.setEnglish(on: false)
        snapshot = type("github")
        check(snapshot.candidates.first?.text != "GitHub", "English words can be turned off")
        _ = engine.process(session, .special(.escape))
        engine.setEnglish(on: true)

        // Fuzzy pinyin through the Swift API: off by default, z = zh on.
        let groups = engine.fuzzyGroups()
        check(groups.count == 10 && groups.allSatisfy { !$0.on } && groups.first?.title == "z = zh",
              "fuzzy pinyin: ten groups, all off, titled like z = zh")
        check(type("zong").candidates.prefix(6).allSatisfy { $0.text != "中" }, "  off: zong is not 中")
        _ = engine.process(session, .special(.escape))
        engine.setFuzzy(["z_zh"])
        check(type("zong").candidates.prefix(6).contains { $0.text == "中" } &&
              engine.fuzzyGroups().first(where: { $0.id == "z_zh" })?.on == true, "  z = zh on: zong offers 中")
        _ = engine.process(session, .special(.escape))
        engine.setFuzzy([])

        // The reranker, as the IME drives it: the key says pending; refine,
        // before the candidates are shown, puts the reranked sentence first.
        if engine.rerank == true {
            var last = Engine.KeyResult()
            for c in "yijiasankouhoubuchepiao" { last = engine.key(session, .character(c)) }
            check(last.contains(.pending), "a key says the reranker may reorder the menu")
            let (refined, reranked) = engine.refine(session)
            check(refined.contains(.dirty) && reranked?.candidates.first?.text == "一家三口候补车票" &&
                  reranked?.candidates.dropFirst().first?.text == "一家三口后部车票" &&
                  engine.refine(session).0.isEmpty,
                  "refine puts the reranked sentence first, the decoder's second, once")
            _ = engine.process(session, .special(.escape))
        } else {
            check(false, "the images hold a reranker")
        }

        snapshot = type("shi")
        (_, after) = engine.process(session, .special(.pageDown))
        check(after?.page == 1 && after?.hasPreviousPage == true && after?.highlighted == 0, "page down")
        (_, after) = engine.process(session, .special(.right))
        check(after?.highlighted == 1, "the arrow keys move the highlight")
        _ = engine.process(session, .special(.escape))


        snapshot = type("nihao")
        (result, after) = engine.process(session, .character("."))
        check(after?.commit == "你好。", "a period commits the best reading and 。")

        snapshot = type("shi`o")
        check(snapshot.preedit == "shi`o" && snapshot.candidates.first?.text == "是",
              "a shape code after `: shi`o gives 是 (the bundled 万象 codes load)")
        _ = engine.process(session, .special(.escape))
        snapshot = type("zhong9")
        check(snapshot.candidates.first?.text == "种", "a tone key: zhong9 gives 种")
        _ = engine.process(session, .special(.escape))

        snapshot = type("gei")
        check(!snapshot.candidates.contains { $0.text == "給" } && !snapshot.isFullCharset,
              "the daily character set: gei leaves 給 out")
        (_, after) = engine.process(session, .character("g", modifiers: .control))
        check(after?.isFullCharset == true && after?.candidates.contains { $0.text == "給" } == true,
              "Control-g shows the full set")
        (_, after) = engine.process(session, .character("g", modifiers: .control))
        check(after?.isFullCharset == false, "and Control-g again goes back")
        _ = engine.process(session, .special(.escape))

        // The user dictionary through the ABI: learn, save, restore, and the no-learn flag.
        engine.setTimeZone()
        engine.forget(.everything)
        func pick(_ input: String, _ text: String, flags: Engine.KeyFlags = []) -> Bool {
            let shown = type(input)
            guard let i = shown.candidates.firstIndex(where: { $0.text == text }), i < 6 else { return false }
            let (_, after) = engine.process(session, .character(Character(String(i + 1))), flags: flags)
            return after?.commit == text
        }
        let before = engine.userDictionaryChanges
        check(pick("xian", "西安") && engine.userDictionaryChanges != before, "picking 西安 for xian teaches the engine")
        check(type("xian").candidates.first?.text == "西安", "  and xian then offers it first")
        _ = engine.process(session, .special(.escape))
        let saved = engine.saveUserDictionary()
        let text = String(decoding: saved, as: UTF8.self)
        check(text.hasPrefix("# OctoDot user dictionary 1\n") && text.contains("西安\txī ān\t"),
              "the saved dictionary comes out as versioned text")
        engine.forget(.everything)
        check(type("xian").candidates.first?.text != "西安", "forgetting everything unlearns it")
        _ = engine.process(session, .special(.escape))
        check(engine.restoreUserDictionary(saved) && type("xian").candidates.first?.text == "西安",
              "restoring the saved bytes brings it back")
        _ = engine.process(session, .special(.escape))
        check(!engine.restoreUserDictionary(Data("garbage".utf8)), "garbage is refused")
        let quiet = engine.userDictionaryChanges
        check(pick("xian", "西安", flags: .noLearn) && engine.userDictionaryChanges == quiet,
              "a pick under the no-learn flag teaches nothing")
        engine.forget(.everything)

        // Input schemes through the ABI.
        let schemes = engine.schemes()
        check(schemes.contains(.init(id: "flypy", name: "小鹤双拼")) && schemes.contains(.init(id: "fullpinyin", name: "全拼")),
              "the bundle offers 全拼 and 小鹤双拼")
        check(engine.setScheme("flypy"), "switching to 小鹤双拼")
        snapshot = type("vsgo")
        check(snapshot.preedit == "vs go" && snapshot.candidates.first?.text == "中国",
              "  vsgo gives 中国, the preedit showing the keys typed, by syllable")
        _ = engine.process(session, .special(.escape))
        check(!engine.setScheme("nope") && engine.setScheme("fullpinyin"), "an unknown scheme is refused; back to 全拼")

        // Lexicon sets and shape codes switched through the ABI.
        let lexiconSets = engine.lexiconSets()
        check(lexiconSets.contains(.init(id: "diming", name: "地名", onByDefault: true, mounted: true)) &&
              lexiconSets.count == 3, "the bundle offers 地名, 名人 and 艺人, mounted")
        check(engine.useSet("diming", on: false) && engine.lexiconSets().first { $0.id == "diming" }?.mounted == false &&
              engine.useSet("diming", on: true), "地名 off and on again")
        let auxSchemes = engine.auxSchemes()
        check(auxSchemes.contains(.init(id: "moqi", name: "墨奇")) && auxSchemes.count == 9, "nine shape-code schemes, named")
        check(engine.setAuxScheme("zrm") && !engine.setAuxScheme("nope") && engine.setAuxScheme("wanxiang"),
              "switching shape codes to 自然码 and back; an unknown one is refused")

        // Custom phrases compiled in the background through the ABI.
        let phraseDir = FileManager.default.temporaryDirectory.appendingPathComponent("octo-phrases-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: phraseDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: phraseDir) }
        let phraseFile = phraseDir.appendingPathComponent("custom_phrases.txt")
        try? Data("龘靐齉\tda bing nang\nme@example.com\tyx\n".utf8).write(to: phraseFile)
        check(engine.compilePhrases(source: phraseFile.path, into: phraseDir.path) != 0, "custom phrases: a job starts")
        let deadline = Date(timeIntervalSinceNow: 10)
        while engine.pump().contains(.pending) && Date() < deadline { usleep(5000) }
        let phrased = engine.phrasesStatus
        check(phrased.state == .ready && phrased.words == 1 && phrased.shortcuts == 1, "  and finishes: 1 word, 1 shortcut")
        check(type("dabingnang").candidates.first?.text == "龘靐齉", "  the word is first for dabingnang")
        _ = engine.process(session, .special(.escape))
        check(type("yx").candidates.first?.text == "me@example.com", "  the shortcut first for yx")
        _ = engine.process(session, .special(.escape))
        try? Data("# empty\n".utf8).write(to: phraseFile)
        _ = engine.compilePhrases(source: phraseFile.path, into: phraseDir.path)
        while engine.pump().contains(.pending) && Date() < deadline { usleep(5000) }

        // The store: sealed at rest, two generations, never crashing on bad files.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("octo-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryKeyProvider()
        let store = UserStore(directory: dir, keys: keys)
        check(store.load() == .empty, "store: nothing stored yet loads as empty")
        let first = Data("# OctoDot user dictionary 1\n西安\txī ān\t2.000\t20399\n".utf8)
        let second = first + Data("说好\tshuō hǎo\t1.000\t20399\n".utf8)
        check(store.save(first) && store.save(second) && store.load() == .loaded(second),
              "store: what was saved last loads back")
        let onDisk = (try? Data(contentsOf: store.current)) ?? Data()
        check(onDisk.prefix(4) == UserStore.magic && onDisk.range(of: Data("西安".utf8)) == nil,
              "store: the file is sealed: no plaintext in it")
        var damaged = onDisk
        damaged[damaged.count / 2] ^= 0x40
        try? damaged.write(to: store.current)
        check(store.load() == .recovered(first), "store: a damaged current file falls back to the previous generation")
        check(FileManager.default.fileExists(atPath: store.current.path + ".unreadable"),
              "  and is moved aside, not overwritten")
        let stranger = UserStore(directory: dir, keys: MemoryKeyProvider())
        check(stranger.load() == .unreadable, "store: under another key nothing opens, and that is not a crash")
        check(store.load() == .empty && store.save(first) && store.load() == .loaded(first),
              "store: after that it starts again empty and saves normally")

        var samples: [UInt64] = []
        for _ in 0..<100 {
            for c in "woshiyigezhongguorenwoaiwodezuguo" {
                let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                let (_, decoded) = engine.process(session, .character(c))
                withExtendedLifetime(decoded) {}
                samples.append(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start)
            }
            _ = engine.process(session, .special(.escape))
        }
        samples.sort()
        func percentile(_ p: Double) -> UInt64 { samples[min(samples.count - 1, Int(Double(samples.count) * p))] / 1000 }
        print("latency  key → engine → snapshot decoded in Swift, \(samples.count) keys of a 33-letter " +
              "sentence: p50 \(percentile(0.5)) µs, p99 \(percentile(0.99)) µs, max \(samples.last! / 1000) µs")
        engine.free(session)
        check(engine.stop(), "the engine stops after typing")
        return failures == 0 ? 0 : 1
    }
}
