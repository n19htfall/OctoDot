import AppKit
import Carbon
import Foundation
import InputMethodKit

/// Commands for installing and testing; macOS never passes these.
///   --register   register the bundle with Text Input Sources (make install)
///   --enable     add its input modes to the user's input sources
///   --disable    remove them again
///   --selftest   start the engine inside the sandbox, type one phrase with
///                the real lexicon and print a JSON verdict
///   --release-test  open the candidate and settings windows out of sight,
///                let them go as a stopping core does, and check they are freed
/// and for the companion's installer (docs/distribution-and-onboarding.md),
/// each run in this IME's own sandbox, never starting the IMK server:
///   --preflight  the container, the App Group and the Keychain key, as JSON
///   --stage-import ID  seal a Transfer from standard input for the running IME
///   --export     the same out, on standard output
///   --wipe       the user dictionary, phrases, key and settings, deleted
@MainActor
enum Maintenance {
    static func run(_ command: String) -> Int32 {
        switch command {
        case "--register":
            let status = TISRegisterInputSource(Bundle.main.bundleURL as CFURL)
            print("TISRegisterInputSource: \(status)")
            return status == noErr ? 0 : 1
        case "--enable":
            return forEachSource { TISEnableInputSource($0) }
        case "--disable":
            return forEachSource { TISDisableInputSource($0) }
        case "--selftest":
            return selfTest()
        case "--preview":
            return preview()
        case "--settings-preview":
            return settingsPreview()
        case "--release-test":
            return releaseTest()
        case "--preflight":
            return preflight()
        case "--stage-import":
            return stageImport()
        case "--export":
            return exportUserData()
        case "--wipe":
            return wipeUserData()
        default:
            print("usage: OctoDot [--register | --enable | --disable | --reload | --selftest]")
            return 2
        }
    }

    // MARK: For the companion's installer

    /// What onboarding checks before the user types (step C): this IME's
    /// container takes a file, the App Group shared with the companion is
    /// there, and the user dictionary's Keychain key reads (made now if there
    /// is none, so any question macOS asks about it comes now, not
    /// mid-sentence).
    private static func preflight() -> Int32 {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let probe = Learning.directory.appendingPathComponent("preflight-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: Learning.directory, withIntermediateDirectories: true)
        let container = FileManager.default.createFile(atPath: probe.path, contents: Data("ok".utf8))
        try? FileManager.default.removeItem(at: probe)
        let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Identity.appGroup)
        var appGroup = false
        if let group {
            try? FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
            let file = group.appendingPathComponent("preflight-\(UUID().uuidString)")
            appGroup = FileManager.default.createFile(atPath: file.path, contents: Data("ok".utf8))
            try? FileManager.default.removeItem(at: file)
        }
        let keychain = KeychainKeyProvider(service: Learning.keychainService).key() != nil
        let images = Core.startEngine() == 0
        Engine.shared.stop()
        let ok = sandboxed && container && appGroup && keychain && images
        print("""
            {"sandboxed": \(sandboxed), "container": \(container), "appGroup": \(appGroup), \
            "keychain": \(keychain), "images": \(images), "ok": \(ok)}
            """)
        return ok ? 0 : 1
    }

    /// Stage encrypted data for the running input method. The identifier is
    /// carried in the notification, while the plaintext stays in the pipe.
    private static func stageImport() -> Int32 {
        guard let id = CommandLine.arguments.last, UUID(uuidString: id) != nil,
              let key = KeychainKeyProvider(service: Learning.keychainService).key() else { return 1 }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard (try? JSONDecoder().decode(Transfer.self, from: input)) != nil else { return 1 }
        let store = UserStore(directory: Learning.directory, keys: KeychainKeyProvider(service: Learning.keychainService))
        guard let sealed = try? store.seal(input, with: key) else { return 1 }
        do {
            try FileManager.default.createDirectory(at: Learning.directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try sealed.write(to: Learning.directory.appendingPathComponent("import-" + id), options: .atomic)
            return 0
        } catch { return 1 }
    }

    /// Called by the active engine on the main thread, serialized with typing
    /// and dictionary saves. A request can be consumed only once.
    static func importStaged(_ id: String) -> Bool {
        guard UUID(uuidString: id) != nil else { return false }
        let file = Learning.directory.appendingPathComponent("import-" + id)
        guard let sealed = try? Data(contentsOf: file) else { return false }
        try? FileManager.default.removeItem(at: file)
        let keys = KeychainKeyProvider(service: Learning.keychainService)
        let store = UserStore(directory: Learning.directory, keys: keys)
        guard let key = keys.key(), let input = store.open(sealed, with: key),
              let transfer = try? JSONDecoder().decode(Transfer.self, from: input) else { return false }
        if let text = transfer.userDictionary, !Learning.importDictionary(text) { return false }
        if let text = transfer.customPhrases {
            let file = Learning.directory.appendingPathComponent("custom_phrases.txt")
            if let old = try? Data(contentsOf: file), old != text {
                try? old.write(to: file.appendingPathExtension("before-import"), options: .atomic)
            }
            guard (try? text.write(to: file, options: .atomic)) != nil else { return false }
        }
        if let data = transfer.preferences,
           let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in values { UserDefaults.standard.set(value, forKey: key) }
            Learning.reloadPreferences()
        }
        return true
    }

    /// The user's data, out, as a Transfer on standard output (for a backup
    /// the companion seals before it writes it anywhere).
    private static func exportUserData() -> Int32 {
        let store = UserStore(directory: Learning.directory, keys: KeychainKeyProvider(service: Learning.keychainService))
        var dictionary: Data?
        switch store.load() {
        case .loaded(let data), .recovered(let data): dictionary = data
        case .empty: dictionary = nil
        case .unreadable: return 1
        }
        let domain = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) }
        let transfer = Transfer(
            userDictionary: dictionary,
            customPhrases: try? Data(contentsOf: Learning.directory.appendingPathComponent("custom_phrases.txt")),
            preferences: domain.flatMap {
                try? PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0)
            })
        guard let data = try? JSONEncoder().encode(transfer) else { return 1 }
        FileHandle.standardOutput.write(data)
        return 0
    }

    /// Everything this IME keeps about its user, gone: the user dictionary
    /// and its previous generation, the phrases and their compiled images,
    /// the Keychain key, the settings.
    private static func wipeUserData() -> Int32 {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: Learning.directory.path)) ?? [] {
            try? fm.removeItem(at: Learning.directory.appendingPathComponent(name))
        }
        KeychainKeyProvider(service: Learning.keychainService).delete()
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        let left = (try? fm.contentsOfDirectory(atPath: Learning.directory.path))?.count ?? 0
        print("{\"ok\": \(left == 0)}")
        return left == 0 ? 0 : 1
    }

    /// A stopping core's windows must be freed: its library stays loaded
    /// after a newer core replaces it (make install reloads in place), and a
    /// window it kept would stay with it, views, drawing buffers and all.
    /// Opens the candidate window and the settings window out of sight, lets
    /// them go as Core.stop does, lets the run loop turn, and checks through
    /// weak references that every one was freed. Prints a JSON verdict.
    private static func releaseTest() -> Int32 {
        guard Core.startEngine() == 0 else {
            print("the images did not load")
            return 1
        }
        final class Weak { weak var object: AnyObject?; init(_ o: AnyObject) { object = o } }
        var watched: [Weak] = []
        for _ in 0..<3 {          // again, as each reload of the core opens its own
            autoreleasepool {
                let page = CandidatePanel.Page(candidates: ["中国", "中", "种"], highlighted: 0,
                                               hasPrevious: false, hasNext: true)
                CandidatePanel.shared.show(page, near: NSRect(x: -30000, y: -30000, width: 2, height: 20),
                                           clientApp: "org.example.OctoDot.release-test")
                let objects = CandidatePanel.liveObjects + SettingsWindow.makeOffscreen()
                watched += objects.map(Weak.init)
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                CandidatePanel.release()
                SettingsWindow.close()
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        Engine.shared.stop()
        let alive = watched.compactMap(\.object).map { String(describing: type(of: $0)) }
        print("{\"watched\": \(watched.count), \"alive\": [\(alive.map { "\"\($0)\"" }.joined(separator: ", "))]}")
        return watched.count > 0 && alive.isEmpty ? 0 : 1
    }

    /// Shows the settings window on screen, each pane in turn, for looking at
    /// the design: --settings-preview [light|dark] [SECONDS]. Prints
    /// "pane NAME window NUMBER" once a pane is in place, for
    /// screencapture -l NUMBER. Only the engine starts (for its lists), not
    /// the learning or the health marker, which the running IME owns.
    private static func settingsPreview() -> Int32 {
        let arguments = CommandLine.arguments
        if arguments.contains("dark") { NSApplication.shared.appearance = NSAppearance(named: .darkAqua) }
        if arguments.contains("light") { NSApplication.shared.appearance = NSAppearance(named: .aqua) }
        let dwell = arguments.compactMap(Double.init).first ?? 1.5
        guard Core.startEngine() == 0 else {
            print("the images did not load")
            return 1
        }
        SettingsWindow.preview(dwell: dwell) { pane, number in
            print("pane \(pane.rawValue) window \(number)")
            fflush(stdout)
        }
        Engine.shared.stop()
        return 0
    }

    /// Shows the candidate window with sample pages at a fixed place, for
    /// looking at the design: --preview [SECONDS] (the highlight walks along).
    private static func preview() -> Int32 {
        let arguments = CommandLine.arguments
        let seconds = arguments.firstIndex(of: "--preview").flatMap { i in
            i + 1 < arguments.count ? Double(arguments[i + 1]) : nil
        } ?? 6
        if let mode = ProcessInfo.processInfo.environment["OCTO_APPEARANCE"] {
            NSApplication.shared.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        }
        let candidates = ["可在我心里的名字", "可在", "可", "刻在", "克", "客"]
        let caret = NSRect(x: 200, y: 600, width: 2, height: 20)
        print("preview: candidate window at x \(Int(caret.minX)), y \(Int(caret.minY)) (screen points, origin bottom left)")
        fflush(stdout)
        var highlight = 0
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            CandidatePanel.shared.show(CandidatePanel.Page(candidates: candidates, highlighted: highlight,
                                                           hasPrevious: highlight > 2, hasNext: true),
                                       near: caret)
            RunLoop.main.run(until: min(end, Date(timeIntervalSinceNow: 1.5)))
            highlight = (highlight + 1) % candidates.count
        }
        return 0
    }

    private static func ourSources() -> [TISInputSource] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let filter = [kTISPropertyBundleID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() else { return [] }
        return (0..<CFArrayGetCount(list)).map {
            unsafeBitCast(CFArrayGetValueAtIndex(list, $0), to: TISInputSource.self)
        }
    }

    private static func forEachSource(_ action: (TISInputSource) -> OSStatus) -> Int32 {
        let sources = ourSources()
        guard !sources.isEmpty else {
            print("no input sources registered for \(Bundle.main.bundleIdentifier ?? "?"); run --register first")
            return 1
        }
        var failed = false
        for source in sources {
            let status = action(source)
            let id = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
                .map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? "?"
            print("\(id): \(status)")
            failed = failed || status != noErr
        }
        return failed ? 1 : 0
    }

    /// The parts a real launch needs, run inside the sandbox: the Goose
    /// runtime starts, the images load from the signed bundle, and typing
    /// works. No IMK server: it would register the input method's own
    /// connection name, and whenever the installed IME was not running (just
    /// after an install), apps connected to the self-test instead, and were
    /// left with a dead connection when it ended. That happened twice on
    /// 2026-11-08, both times ending in a crash inside IMK.
    private static func selfTest() -> Int32 {
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        let status = Core.startEngine()

        let session = Engine.shared.newSession(clientBundleID: "selftest")
        for c in "zhongguoren" { _ = Engine.shared.key(session, .character(c)) }
        let (result, snapshot) = Engine.shared.process(session, .special(.space))
        let committed = result.contains(.hasCommit) && snapshot?.commit == "中国人"

        // The Keychain from inside the sandbox: a key is made, read back the
        // same, and removed (a probe item of its own, never the real key).
        let probe = KeychainKeyProvider(service: Learning.keychainService + ".selftest")
        probe.delete()
        let made = probe.key()?.withUnsafeBytes { Data($0) }
        let again = probe.key()?.withUnsafeBytes { Data($0) }
        probe.delete()
        let keychain = made != nil && made == again

        // The sealed store in the container, with that kind of key.
        let directory = Learning.directory.appendingPathComponent("selftest", isDirectory: true)
        let store = UserStore(directory: directory, keys: MemoryKeyProvider())
        let sample = Engine.shared.saveUserDictionary()
        let stored = store.save(sample) && store.load() == .loaded(sample)
        try? FileManager.default.removeItem(at: directory)

        // The bundle's lexicon sets, all mounted (packaging checks); its grammar
        // pin, and the model it pins mapped from the shared folder, when that
        // holds it (the companion puts it there; a fresh Mac has none).
        let sets = Engine.shared.lexiconSets().filter(\.mounted).count
        let pin = Core.grammarPin
        let shared = pin?.isInstalled ?? false
        let grammar = pin != nil && (!shared || Engine.shared.grammar == .on)
        let grammarState = pin == nil ? "\"no pin\"" : shared ? "\(Engine.shared.grammar == .on)" : "\"not installed\""
        // The reranker's weights, mapped from the bundle inside the sandbox
        // (a bundle built without a model has none: nothing to check).
        let bundled = FileManager.default.fileExists(atPath: Core.dataDirectory + "/rerank.img")
        let rerank = !bundled || Engine.shared.rerank != nil

        // A custom phrase list compiled by a contained worker inside the sandbox.
        let phrasesDir = Learning.directory.appendingPathComponent("selftest-phrases", isDirectory: true)
        try? FileManager.default.createDirectory(at: phrasesDir, withIntermediateDirectories: true)
        let source = phrasesDir.appendingPathComponent("custom_phrases.txt")
        try? Data("龘靐齉\tda bing nang\n我的邮箱\tyx\n".utf8).write(to: source)
        var phrases = false
        var phrasesWhy = "the job did not start"
        if Engine.shared.compilePhrases(source: source.path, into: phrasesDir.path) != 0 {
            let deadline = Date(timeIntervalSinceNow: 30)
            while Engine.shared.pump().contains(.pending) && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            let s = Engine.shared.phrasesStatus
            phrases = s.state == .ready && s.words == 1 && s.shortcuts == 1
            phrasesWhy = "\(s.state.rawValue), \(s.words) words, \(s.shortcuts) shortcuts, \(s.skipped) skipped"
        }
        try? FileManager.default.removeItem(at: phrasesDir)

        // Saving the list takes effect by itself: the file created, written in
        // place, and replaced the way TextEdit saves (a new copy renamed over it).
        let watchDir = Learning.directory.appendingPathComponent("selftest-watch", isDirectory: true)
        try? FileManager.default.removeItem(at: watchDir)
        try? FileManager.default.createDirectory(at: watchDir, withIntermediateDirectories: true)
        Phrases.directory = watchDir
        Phrases.start()
        func settles(words: Int) -> Bool {
            let deadline = Date(timeIntervalSinceNow: 5)
            while Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
                let s = Engine.shared.phrasesStatus
                if s.state == .ready && s.words == words { return true }
            }
            return false
        }
        try? Data("龘龘 da da\n".utf8).write(to: Phrases.file)
        let created = settles(words: 1)
        try? Data("龘龘 da da\n靐靐 bing bing\n".utf8).write(to: Phrases.file)        // in place
        let inPlace = settles(words: 2)
        try? Data("龘龘 da da\n靐靐 bing bing\n齉齉 nang nang\n".utf8).write(to: Phrases.file, options: .atomic)
        let replaced = settles(words: 3)
        try? Data("龘龘 da da\n".utf8).write(to: Phrases.file)                         // the new file, in place
        let rearmed = settles(words: 1)
        Phrases.stop()
        Phrases.directory = nil
        try? FileManager.default.removeItem(at: watchDir)
        let watched = created && inPlace && replaced && rearmed

        // A CI runner may have no unlocked login keychain; there, and only when
        // asked, its absence does not fail the self-test.
        let keychainOptional = ProcessInfo.processInfo.environment["OCTO_SELFTEST_ALLOW_NO_KEYCHAIN"] != nil
        let ok = sandboxed && status == 0 && committed && (keychain || keychainOptional) && stored && sets == 3 &&
                 grammar && rerank && phrases && watched
        print("""
            {"sandboxed": \(sandboxed), "images": \(status), "engine_commit": \(committed), \
            "keychain": \(keychain), "store": \(stored), \
            "sets": \(sets), "grammar": \(grammarState), "rerank": \(bundled ? "\(rerank)" : "\"none\""), \
            "phrases": \(phrases), \(phrases ? "" : "\"phrases_status\": \"\(phrasesWhy)\", ")\
            "saved_phrases_apply": {"created": \(created), "in_place": \(inPlace), "replaced": \(replaced), \
            "after_replace": \(rearmed)}, "ok": \(ok)}
            """)
        fflush(stdout)
        return ok ? 0 : 1
    }
}
