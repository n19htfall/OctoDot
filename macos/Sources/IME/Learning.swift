import AppKit
import Carbon.HIToolbox
import Foundation

/// The IME's side of learning: when the engine may learn from a key (the
/// privacy policy), and keeping the user dictionary sealed on disk.
@MainActor
enum Learning {
    /// Apps whose typing never teaches the dictionary: password managers.
    static let noLearnApps: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
        "com.apple.keychainaccess", "com.apple.Passwords", "org.keepassxc.keepassxc",
        "com.lastpass.LastPass", "com.dashlane.dashlanephonefinal",
    ]

    private static let incognitoKey = "incognito"
    private static let schemeKey = "scheme"

    /// The input scheme in use, remembered across launches.
    static var scheme: String {
        get { UserDefaults.standard.string(forKey: schemeKey) ?? "fullpinyin" }
        set { UserDefaults.standard.set(newValue, forKey: schemeKey) }
    }

    /// Switches the engine to `id` and remembers it, if the engine has it.
    static func useScheme(_ id: String) {
        if Engine.shared.setScheme(id) { scheme = id }
    }

    private static let auxSchemeKey = "auxScheme"
    private static let setsKey = "lexiconSets"
    private static let grammarKey = "grammarModel"
    private static let englishKey = "englishWords"
    private static let englishSpaceKey = "englishSpace"
    private static let rerankKey = "reranker"
    private static let fullCharsetKey = "fullCharset"
    private static let fuzzyKey = "fuzzyPinyin"

    /// The fuzzy pinyin groups on (by id, "z_zh"), remembered across
    /// launches: none unless the user turns some on.
    static var fuzzy: [String] {
        get { UserDefaults.standard.stringArray(forKey: fuzzyKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: fuzzyKey) }
    }

    static func useFuzzy(_ id: String, on: Bool) {
        var ids = fuzzy.filter { $0 != id }
        if on { ids.append(id) }
        Engine.shared.setFuzzy(ids)
        fuzzy = ids
    }

    /// The full character set by default, remembered across launches: off
    /// (万象's daily characters) unless turned on.
    static var fullCharset: Bool {
        get { UserDefaults.standard.bool(forKey: fullCharsetKey) }
        set { UserDefaults.standard.set(newValue, forKey: fullCharsetKey) }
    }

    static func useFullCharset(_ on: Bool) {
        Engine.shared.setFullCharset(on: on)
        fullCharset = on
    }

    /// English words beside the Chinese, remembered across launches: on unless turned off.
    static var englishOn: Bool {
        get { UserDefaults.standard.object(forKey: englishKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: englishKey) }
    }

    static func useEnglish(_ on: Bool) {
        Engine.shared.setEnglish(on: on)
        englishOn = on
    }

    /// A space between consecutive English words. Off unless turned on.
    static var englishSpace: Bool {
        get { UserDefaults.standard.bool(forKey: englishSpaceKey) }
        set { UserDefaults.standard.set(newValue, forKey: englishSpaceKey) }
    }

    static func useEnglishSpace(_ on: Bool) {
        Engine.shared.setEnglishSpace(on: on)
        englishSpace = on
    }

    /// The reranker, remembered across launches: on unless turned off.
    static var rerankOn: Bool {
        get { UserDefaults.standard.object(forKey: rerankKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: rerankKey) }
    }

    static func useRerank(_ on: Bool) {
        Engine.shared.setRerank(on: on)
        rerankOn = on
    }

    /// Whether the grammar model is on, remembered across launches: on unless turned off.
    static var grammarOn: Bool {
        get { UserDefaults.standard.object(forKey: grammarKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: grammarKey) }
    }

    static func useGrammar(_ on: Bool) {
        if Engine.shared.setGrammar(on: on) || !on { grammarOn = on }
    }

    /// The companion has put the grammar model in the shared folder: turned
    /// on now, unless the user turned it off.
    static func reopenGrammar() {
        if grammarOn && Engine.shared.grammar != .on { Engine.shared.setGrammar(on: true) }
    }

    /// The shape-code scheme, remembered across launches.
    static var auxScheme: String {
        get { UserDefaults.standard.string(forKey: auxSchemeKey) ?? "wanxiang" }
        set { UserDefaults.standard.set(newValue, forKey: auxSchemeKey) }
    }

    static func useAuxScheme(_ id: String) {
        if Engine.shared.setAuxScheme(id) { auxScheme = id }
    }

    /// The user's own choices for lexicon sets, by id; a set not listed keeps its default.
    private static var setChoices: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: setsKey) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: setsKey) }
    }

    /// Turns a set on or off at once, and remembers the choice.
    static func useSet(_ id: String, on: Bool) {
        if Engine.shared.useSet(id, on: on) { setChoices[id] = on }
    }

    /// The remembered choices, applied after the engine opened its images.
    private static func applyPreferences() {
        if auxScheme != "wanxiang" && !Engine.shared.setAuxScheme(auxScheme) { auxScheme = "wanxiang" }
        let choices = setChoices
        for set in Engine.shared.lexiconSets() {
            if let on = choices[set.id], on != set.mounted { Engine.shared.useSet(set.id, on: on) }
        }
        if !grammarOn && Engine.shared.grammar == .on { Engine.shared.setGrammar(on: false) }
        Engine.shared.setEnglish(on: englishOn)
        Engine.shared.setEnglishSpace(on: englishSpace)
        Engine.shared.setRerank(on: rerankOn)
        Engine.shared.setFullCharset(on: fullCharset)
        Engine.shared.setFuzzy(fuzzy)
    }

    /// Incognito: nothing typed teaches the dictionary until it is turned off.
    static var incognito: Bool {
        get { UserDefaults.standard.bool(forKey: incognitoKey) }
        set { UserDefaults.standard.set(newValue, forKey: incognitoKey) }
    }

    /// The flags for a key typed into `app`: no learning in a secure field
    /// (a password box anywhere), in a no-learn app, or in incognito.
    static func flags(forApp app: String) -> Engine.KeyFlags {
        if incognito || IsSecureEventInputEnabled() || noLearnApps.contains(app) { return .noLearn }
        return []
    }

    // MARK: The dictionary on disk

    private static var store: UserStore?
    private static var savedChanges: UInt64 = 0
    private static var pending: Timer?
    private static let saveDelay: TimeInterval = 5
    private static var observers: [any NSObjectProtocol] = []

    /// The IME's own container: ~/Library/Containers/<bundle id>/Data/Library/Application Support/OctoDot.
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OctoDot", isDirectory: true)
    }

    static var keychainService: String { (Bundle.main.bundleIdentifier ?? "OctoDot") + ".user-dictionary" }

    /// Loads the sealed dictionary into the engine (after it opened its images).
    static func start() {
        Engine.shared.setTimeZone()
        if scheme != "fullpinyin" && !Engine.shared.setScheme(scheme) {
            log.error("input scheme \(scheme, privacy: .public) is not available; using full pinyin")
            scheme = "fullpinyin"
        }
        applyPreferences()
        let store = UserStore(directory: directory, keys: KeychainKeyProvider(service: keychainService))
        Self.store = store
        switch store.load() {
        case .loaded(let data):
            if !Engine.shared.restoreUserDictionary(data) { log.error("user dictionary: not in the expected format") }
        case .recovered(let data):
            log.error("user dictionary: the current file did not open; loaded the previous one")
            Engine.shared.restoreUserDictionary(data)
        case .empty:
            break
        case .unreadable:
            log.error("user dictionary: no file opens with this key; starting empty, the old files set aside")
        }
        savedChanges = Engine.shared.userDictionaryChanges
        takeOverJournal()
        observers = [
            NotificationCenter.default.addObserver(forName: .NSSystemTimeZoneDidChange, object: nil,
                                                   queue: .main) { _ in
                MainActor.assumeIsolated { Engine.shared.setTimeZone() }
            },
        ]
    }

    /// The core stops (the launcher quits, or loads a newer core): the
    /// dictionary is saved while the engine is still there.
    static func stop() {
        saveNow()
        handOverJournal()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        store = nil
    }

    // MARK: The last 15 minutes, across a core reload

    /// Where a stopping core leaves the last 15 minutes of learning for the
    /// next one: a volatile defaults domain, which lives in this process's
    /// memory and is never written to disk. An update loads a new core into
    /// the same process, which takes it over, so "Forget the Last 15 Minutes"
    /// still covers what was learned before the update. A quit or a crash
    /// takes it with the process: no times of typing are ever stored.
    private static let handOverDomain = "OctoDot.journal"

    private static func handOverJournal() {
        let journal = Engine.shared.journal()
        guard !journal.isEmpty else { return }
        UserDefaults.standard.setVolatileDomain(["journal": journal], forName: handOverDomain)
    }

    private static func takeOverJournal() {
        let defaults = UserDefaults.standard
        guard defaults.volatileDomainNames.contains(handOverDomain) else { return }
        let domain = defaults.volatileDomain(forName: handOverDomain)
        defaults.removeVolatileDomain(forName: handOverDomain)
        if let journal = domain["journal"] as? Data {
            let taken = Engine.shared.restoreJournal(journal)
            log.notice("took over \(taken, privacy: .public) recent changes from the core before")
        }
    }

    /// After a key: if the dictionary changed, save once typing pauses.
    static func noteActivity() {
        guard store != nil, Engine.shared.userDictionaryChanges != savedChanges, pending == nil else { return }
        pending = Timer.scheduledTimer(withTimeInterval: saveDelay, repeats: false) { _ in
            MainActor.assumeIsolated {
                pending = nil
                saveNow()
            }
        }
    }

    /// Saves now if anything changed (also when the input method is switched away).
    static func saveNow() {
        pending?.invalidate()
        pending = nil
        guard let store else { return }
        let changes = Engine.shared.userDictionaryChanges
        guard changes != savedChanges else { return }
        if store.save(Engine.shared.saveUserDictionary()) {
            // Saving can discard expired entries and advance the revision.
            savedChanges = Engine.shared.userDictionaryChanges
        } else {
            log.error("user dictionary: could not save")
        }
    }

    static func forget(_ scope: Engine.ForgetScope) {
        Engine.shared.forget(scope)
        saveNow()
    }
}
