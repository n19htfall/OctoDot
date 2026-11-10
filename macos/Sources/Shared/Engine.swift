import Foundation

/// The Swift side of the engine's C ABI (macos/engine/ime.goose).
///
/// Goose requires every exported call to come from the thread that ran
/// `goose_init`. `@MainActor` turns that runtime rule into a compile-time
/// one: IMK delivers events on the main thread, and code off the main actor
/// cannot reach the engine at all. (A GCD serial queue would not be enough:
/// it serializes work but may run it on different threads.)
@MainActor
final class Engine {
    static let shared = Engine()

    /// The ABI this host was written against. The engine reports its own.
    static let abiVersion: UInt32 = 17

    struct Session: Hashable, Sendable {
        fileprivate let handle: UInt64
    }

    struct KeyResult: OptionSet, Sendable {
        let rawValue: UInt32
        static let handled = KeyResult(rawValue: 1)
        static let dirty = KeyResult(rawValue: 2)
        static let hasCommit = KeyResult(rawValue: 4)
        /// The reranker may reorder the menu: call `refine` before showing the candidates.
        static let pending = KeyResult(rawValue: 8)
    }

    /// session::KEY_* in engine/session.goose. `.other`: the codepoint alone
    /// describes the key.
    enum Key: UInt32, Sendable {
        case other = 0, backspace, escape, enter, space, left, right, up, down, pageUp, pageDown, home, end
    }

    /// session::KEYFLAG_*: the host's privacy policy for one key.
    struct KeyFlags: OptionSet, Sendable {
        let rawValue: UInt32
        static let noLearn = KeyFlags(rawValue: 1)
        /// `codepoint` is a candidate index to commit (a click in the window).
        static let pick = KeyFlags(rawValue: 2)
    }

    /// What octo_forget takes back.
    enum ForgetScope: UInt32, Sendable {
        case lastFifteenMinutes = 0, today, everything
    }

    struct Modifiers: OptionSet, Sendable {
        let rawValue: UInt32
        static let shift = Modifiers(rawValue: 1)
        static let control = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    private(set) var isStarted = false
    /// The lexicon and spelling table loaded. Until then every key passes
    /// through to the app, so a missing or damaged image never blocks typing.
    private(set) var isReady = false

    private init() {}

    /// Starts the Goose runtime on the main thread (once) and loads the
    /// images from `dataDirectory`, looking for the grammar model's file in
    /// `grammarFolder` when it is not beside them. Returns the engine's
    /// status: 0, or what failed (see octo_open).
    @discardableResult
    func start(dataDirectory: String, grammarFolder: String? = nil) -> Int32 {
        if !isStarted {
            goose_init(CommandLine.argc, CommandLine.unsafeArgv)
            let abi = octo_abi_version()
            precondition(abi == Self.abiVersion, "engine ABI \(abi), host expects \(Self.abiVersion)")
            isStarted = true
        }
        withSlice(grammarFolder ?? "") { octo_set_grammar_folder($0) }
        let status = withSlice(dataDirectory) { octo_open($0) }
        isReady = status == 0
        return status
    }

    func newSession(clientBundleID: String) -> Session {
        Session(handle: withSlice(clientBundleID) { octo_session_new($0) })
    }

    /// Ends the engine: the IME's core is being replaced by a newer build, or
    /// the process quits. What lives outside the runtime is released
    /// (octo_close), then the runtime itself (goose_exit), so the next core
    /// starts its own and this one's memory goes back. goose_exit with a
    /// thread of the program still running is a runtime error, so a custom
    /// phrase compile in flight gets a few seconds to finish; if it does not,
    /// the runtime remains started and this returns false.
    @discardableResult
    func stop() -> Bool {
        guard isStarted else { return true }
        isReady = false
        var waited = 0
        while pump().contains(.pending) && waited < 150 {
            usleep(20_000)
            waited += 1
        }
        guard waited < 150 else { return false }
        isStarted = false
        octo_close()
        goose_exit()
        return true
    }

    func free(_ session: Session) {
        guard isStarted else { return }
        octo_session_free(session.handle)
    }

    func reset(_ session: Session) { octo_reset(session.handle) }

    func key(_ session: Session, _ key: TranslatedKey, flags: KeyFlags = []) -> KeyResult {
        KeyResult(rawValue: octo_key(session.handle, key.key.rawValue, key.modifiers.rawValue, key.codepoint,
                                     flags.rawValue))
    }

    func armPickText(_ session: Session, _ text: String) {
        guard isStarted, !text.isEmpty else { return }
        withSlice(text) { octo_set_pick_text(session.handle, $0) }
    }

    // MARK: Input schemes

    struct Scheme: Sendable, Equatable {
        var id: String          // "flypy"
        var name: String        // "小鹤双拼"
    }

    /// The schemes the data directory holds, as the engine verified them.
    func schemes() -> [Scheme] {
        var length: Int64 = 0
        guard let bytes = octo_schemes(&length), length > 0 else { return [] }
        let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(length)), as: UTF8.self)
        return text.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            return fields.count >= 2 ? Scheme(id: String(fields[0]), name: String(fields[1])) : nil
        }
    }

    /// Switches the input scheme; false (keeping the current one) if it is not there.
    @discardableResult
    func setScheme(_ id: String) -> Bool { withSlice(id) { octo_set_scheme($0) } == 0 }

    // MARK: Lexicon sets and shape codes (docs/hotswap-architecture.md)

    struct LexiconSet: Sendable, Equatable {
        var id: String              // "diming"
        var name: String            // "地名"
        var onByDefault: Bool
        var mounted: Bool
    }

    func lexiconSets() -> [LexiconSet] {
        lines(octo_sets).compactMap { f in
            f.count >= 4 ? LexiconSet(id: f[0], name: f[1], onByDefault: f[2] == "on", mounted: f[3] == "mounted") : nil
        }
    }

    /// Turns a set on or off at once; false if that cannot be done.
    @discardableResult
    func useSet(_ id: String, on: Bool) -> Bool { withSlice(id) { octo_mount($0, on ? 1 : 0) } == 0 }

    func auxSchemes() -> [Scheme] {
        lines(octo_aux_schemes).compactMap { f in f.count >= 2 ? Scheme(id: f[0], name: f[1]) : nil }
    }

    @discardableResult
    func setAuxScheme(_ id: String) -> Bool { withSlice(id) { octo_set_aux_scheme($0) } == 0 }

    /// Returns memory the engine no longer uses to the system.
    func trim() {
        guard isStarted else { return }
        octo_trim()
    }

    // MARK: The grammar model (engine/grammar.goose, docs/M2-grammar.md)

    enum GrammarState: Sendable { case absent, off, on }

    var grammar: GrammarState {
        switch octo_grammar() {
        case 1: return .on
        case 0: return .off
        default: return .absent
        }
    }

    /// Turns the grammar model on or off at once; false if it cannot be turned on.
    @discardableResult
    func setGrammar(on: Bool) -> Bool { octo_set_grammar(on ? 1 : 0) == 0 }

    // MARK: English words (docs/english-design.md)

    /// Whether English words are offered beside the Chinese. On by default.
    var english: Bool { octo_english() == 1 }

    func setEnglish(on: Bool) { octo_set_english(on ? 1 : 0) }

    /// A space between consecutive English words. Off by default.
    func setEnglishSpace(on: Bool) { octo_set_english_space(on ? 1 : 0) }

    // MARK: The reranker (docs/rerank-design.md)

    /// Whether the reranker is on, or nil if the images have none.
    var rerank: Bool? {
        let state = octo_rerank()
        return state < 0 ? nil : state == 1
    }

    func setRerank(on: Bool) { octo_set_rerank(on ? 1 : 0) }

    // MARK: The character set

    /// Every character, or only 万象's daily ones (the default Control-G
    /// switches from while composing).
    var fullCharset: Bool { octo_full_charset() == 1 }

    func setFullCharset(on: Bool) { octo_set_full_charset(on ? 1 : 0) }

    // MARK: Fuzzy pinyin (docs/fuzzy-pinyin.md)

    /// A fuzzy group: two spellings typed as one sound ("z_zh": z = zh).
    struct FuzzyGroup: Hashable, Sendable {
        var id: String
        var on: Bool
        /// "z = zh", for showing.
        var title: String { id.split(separator: "_").joined(separator: " = ") }
    }

    /// The scheme's fuzzy groups, in order, and which are on.
    func fuzzyGroups() -> [FuzzyGroup] {
        lines(octo_fuzzy_groups).compactMap { f in f.count == 2 ? FuzzyGroup(id: f[0], on: f[1] == "1") : nil }
    }

    /// Turns on exactly these groups (by id); none turns fuzzy pinyin off.
    func setFuzzy(_ ids: [String]) { withSlice(ids.joined(separator: " ")) { octo_set_fuzzy($0) } }

    // MARK: Custom phrases (engine/phrases.goose)

    struct PumpResult: OptionSet, Sendable {
        let rawValue: UInt32
        static let changed = PumpResult(rawValue: 1)
        static let pending = PumpResult(rawValue: 2)
    }

    struct PhrasesStatus: Sendable, Equatable {
        enum State: String, Sendable { case idle, compiling, ready, failed }
        var state: State
        var words: Int
        var shortcuts: Int
        var skipped: Int
        var firstBadLine: Int
        var why: String
    }

    /// Starts compiling `source` into images in `directory`; the job id, or 0.
    func compilePhrases(source: String, into directory: String) -> UInt64 {
        withSlice(source) { s in withSlice(directory) { d in octo_compile_phrases(s, d) } }
    }

    func pump() -> PumpResult { PumpResult(rawValue: octo_pump()) }

    var phrasesStatus: PhrasesStatus {
        let f = lines(octo_phrases_status).first ?? []
        guard f.count >= 6, let state = PhrasesStatus.State(rawValue: f[0]) else {
            return PhrasesStatus(state: .idle, words: 0, shortcuts: 0, skipped: 0, firstBadLine: 0, why: "")
        }
        return PhrasesStatus(state: state, words: Int(f[1]) ?? 0, shortcuts: Int(f[2]) ?? 0, skipped: Int(f[3]) ?? 0,
                             firstBadLine: Int(f[4]) ?? 0, why: f[5...].joined(separator: "\t"))
    }

    @discardableResult
    func mountPhrases(from directory: String) -> Bool { withSlice(directory) { octo_mount_phrases($0) } == 0 }

    /// A lent text of tab-separated lines, copied out and split.
    private func lines(_ call: (UnsafeMutablePointer<Int64>?) -> UnsafePointer<UInt8>?) -> [[String]] {
        var length: Int64 = 0
        guard let bytes = call(&length), length > 0 else { return [] }
        let text = String(decoding: UnsafeRawBufferPointer(start: bytes, count: Int(length)), as: UTF8.self)
        return text.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }

    // MARK: The user dictionary

    /// The user dictionary as text, copied out of the engine (which lends it).
    func saveUserDictionary() -> Data {
        var length: Int64 = 0
        guard let bytes = octo_user_save(&length), length > 0 else { return Data() }
        return Data(bytes: bytes, count: Int(length))
    }

    /// Replaces the user dictionary; false (leaving it empty) if `data` is not one.
    @discardableResult
    func restoreUserDictionary(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            octo_user_restore(sl_u8(data: UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress),
                                    len: Int64(raw.count))) == 0
        }
    }

    /// The last 15 minutes of learning, by what changed: what the next core
    /// in this process takes over (restoreJournal), so it can forget them.
    func journal() -> Data {
        guard isStarted else { return Data() }
        var length: Int64 = 0
        guard let bytes = octo_journal_save(&length), length > 0 else { return Data() }
        return Data(bytes: bytes, count: Int(length))
    }

    /// Takes over a journal from the core before, after its dictionary was
    /// restored: how many changes came back.
    @discardableResult
    func restoreJournal(_ data: Data) -> Int {
        data.withUnsafeBytes { raw in
            Int(octo_journal_restore(sl_u8(data: UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress),
                                           len: Int64(raw.count))))
        }
    }

    /// Moves whenever the user dictionary changes.
    var userDictionaryChanges: UInt64 { octo_user_changes() }

    @discardableResult
    func forget(_ scope: ForgetScope) -> UInt32 { octo_forget(scope.rawValue) }

    func setTimeZone(_ zone: TimeZone = .current) {
        octo_set_utc_offset(Int32(zone.secondsFromGMT()))
    }

    /// The engine lends the snapshot bytes only until the next call into it,
    /// so they are decoded (copied) here, before anything else can run.
    func snapshot(_ session: Session) -> Snapshot {
        var length: Int64 = 0
        guard let bytes = octo_snapshot(session.handle, &length), length > 0 else { return .empty }
        return Snapshot(bytes: UnsafeRawBufferPointer(start: bytes, count: Int(length))) ?? .empty
    }

    /// One key, and the snapshot when the key changed something.
    func process(_ session: Session, _ key: TranslatedKey, flags: KeyFlags = []) -> (KeyResult, Snapshot?) {
        let result = self.key(session, key, flags: flags)
        let changed = result.contains(.dirty) || result.contains(.hasCommit)
        return (result, changed ? snapshot(session) : nil)
    }

    /// After a key whose result was `.pending`, before showing its candidates:
    /// the reranker reorders the menu (engine/rerank.goose, a few
    /// milliseconds), with a snapshot to show if it changed.
    func refine(_ session: Session) -> (KeyResult, Snapshot?) {
        let result = KeyResult(rawValue: octo_refine(session.handle))
        return (result, result.contains(.dirty) ? snapshot(session) : nil)
    }

    private func withSlice<R>(_ text: String, _ body: (sl_u8) -> R) -> R {
        var copy = text
        return copy.withUTF8 { utf8 in
            body(sl_u8(data: UnsafeMutablePointer(mutating: utf8.baseAddress), len: Int64(utf8.count)))
        }
    }
}

/// A key as the engine sees it, made from an NSEvent by the IME (or by a test).
struct TranslatedKey: Sendable {
    var key: Engine.Key
    var codepoint: UInt32
    var modifiers: Engine.Modifiers

    static func character(_ c: Character, modifiers: Engine.Modifiers = []) -> TranslatedKey {
        TranslatedKey(key: .other, codepoint: c.unicodeScalars.first!.value, modifiers: modifiers)
    }

    static func special(_ key: Engine.Key) -> TranslatedKey {
        TranslatedKey(key: key, codepoint: 0, modifiers: [])
    }
}
