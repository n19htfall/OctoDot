import Foundation
import SQLite3
@preconcurrency import Translation

/// The privacy policy for candidate lookups. Incognito requires an explicit
/// Option hold and keeps no results after it ends.
enum CandidateLookupPolicy: Equatable {
    case normal, incognito, disabled
}

enum CandidateLanguage: Hashable, Sendable {
    case chinese, english

    /// Classify the candidate, not the pinyin used to type it. Mixed Chinese
    /// and English is translated as Chinese; addresses and shortcuts stay out.
    static func of(_ text: String) -> CandidateLanguage? {
        guard !text.isEmpty, text.count <= 80, !text.contains("@"), !text.contains("://"),
              !text.contains("\\"), !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        if text.unicodeScalars.contains(where: { $0.properties.isIdeographic }) { return .chinese }
        if text.unicodeScalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }) {
            return .english
        }
        return nil
    }
}

struct CandidateLookupKey: Hashable, Sendable {
    let text: String
    let language: CandidateLanguage
}

enum CandidateLookupResult: Equatable, Sendable {
    case translation(String)
    case needsLanguages
    case unavailable

    var caption: String {
        switch self {
        case .translation(let text): text
        case .needsLanguages: "请下载翻译语言"
        case .unavailable: "—"
        }
    }
}

enum MachineTranslation: Equatable, Sendable {
    case text(String)
    case needsLanguages
    case unavailable
}

/// A fake provider can control timing and replies in the typing tests.
@MainActor
protocol CandidateLookupProvider: AnyObject, Sendable {
    func glossary(_ key: CandidateLookupKey) async -> String?
    func translate(_ key: CandidateLookupKey) async -> MachineTranslation
}

/// Replaceable queues for the visible page. The fast glossary can make
/// progress while one slower system translation is in flight.
@MainActor
final class CandidateTranslations {
    private struct Cached {
        var result: CandidateLookupResult
        var expires: Date
    }

    private let provider: any CandidateLookupProvider
    private var cache: [CandidateLookupKey: Cached] = [:]
    private var order: [CandidateLookupKey] = []
    private var page: [CandidateLookupKey?] = []
    private var priority: [CandidateLookupKey] = []
    private var queued: [CandidateLookupKey] = []
    private var inFlight: CandidateLookupKey?
    private var worker: Task<Void, Never>?
    private var fallbackQueued: [CandidateLookupKey] = []
    private var fallbackInFlight: CandidateLookupKey?
    private var fallbackWorker: Task<Void, Never>?
    private var epoch: UInt64 = 0
    private var policy: CandidateLookupPolicy = .disabled
    private var optionDown = false
    private let changed: @MainActor () -> Void
    private let maxEntries = 128

    init(provider: any CandidateLookupProvider, changed: @escaping @MainActor () -> Void) {
        self.provider = provider
        self.changed = changed
    }

    static var supported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    func setPage(_ candidates: [String], highlighted: Int, policy: CandidateLookupPolicy) {
        if self.policy != policy {
            epoch &+= 1
            cancelWorkers()
            queued.removeAll()
            fallbackQueued.removeAll()
            cache.removeAll()
            order.removeAll()
        }
        self.policy = policy
        guard policy != .disabled else { page = []; priority = []; return }
        let nextPage = candidates.map { text in
            CandidateLanguage.of(text).map { CandidateLookupKey(text: text, language: $0) }
        }
        if policy == .incognito && nextPage != page {
            epoch &+= 1
            cancelWorkers()
            cache.removeAll()
            order.removeAll()
        }
        page = nextPage
        // Prefer the highlighted word, then the other words on this page.
        var candidates = page.compactMap { $0 }
        if page.indices.contains(highlighted), let first = page[highlighted] {
            candidates.removeAll { $0 == first }
            candidates.insert(first, at: 0)
        }
        var seen = Set<CandidateLookupKey>()
        priority = candidates.filter { seen.insert($0).inserted }
        fallbackQueued = priority.filter { fallbackQueued.contains($0) && cached($0) == nil }
        queued = priority.filter {
            $0 != inFlight && $0 != fallbackInFlight && !fallbackQueued.contains($0) && cached($0) == nil
        }
        if policy == .normal || optionDown { startWorkers() }
    }

    func setOptionDown(_ down: Bool) {
        guard optionDown != down else { return }
        optionDown = down
        if policy == .incognito && !down {
            epoch &+= 1
            cancelWorkers()
            queued.removeAll()
            fallbackQueued.removeAll()
            cache.removeAll()
            order.removeAll()
        } else if down {
            // An incognito page is not prefetched; make its requests now.
            queued = priority.filter {
                $0 != inFlight && $0 != fallbackInFlight && !fallbackQueued.contains($0) && cached($0) == nil
            }
            startWorkers()
        }
    }

    func captions() -> [String] {
        page.map { key in
            guard let key else { return "—" }
            return cached(key)?.caption ?? "…"
        }
    }

    /// What replaces each candidate while Option is held. Empty until there is
    /// a translation or the missing-language notice.
    func replacements() -> [String] {
        page.map { key in
            guard let key, let result = cached(key) else { return "" }
            switch result {
            case .translation, .needsLanguages: return result.caption
            case .unavailable: return ""
            }
        }
    }

    func committedText(for candidate: String) -> String? {
        guard let language = CandidateLanguage.of(candidate) else { return nil }
        guard case .translation(let text) = cached(CandidateLookupKey(text: candidate, language: language)) else {
            return nil
        }
        guard !text.isEmpty, text != candidate else { return nil }
        return text
    }

    /// Drop both retained results and pending work. Epoch makes any eventual
    /// answer from an already-running lookup harmless.
    func clear() {
        epoch &+= 1
        cancelWorkers()
        page.removeAll()
        priority.removeAll()
        queued.removeAll()
        fallbackQueued.removeAll()
        cache.removeAll()
        order.removeAll()
        policy = .disabled
        optionDown = false
    }

    /// Keep visible replacements usable while Option is held. Otherwise the
    /// next hold can repopulate the small cache from the current page.
    func trim() {
        guard !optionDown else { return }
        cache.removeAll()
        order.removeAll()
    }

    private func cached(_ key: CandidateLookupKey) -> CandidateLookupResult? {
        guard let item = cache[key] else { return nil }
        // Do not let a visible replacement expire while it can be selected.
        if item.expires <= Date() && !(optionDown && page.contains(key)) {
            cache.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        order.removeAll { $0 == key }
        order.append(key)
        return item.result
    }

    private func remember(_ result: CandidateLookupResult, for key: CandidateLookupKey) {
        let seconds: TimeInterval
        switch result {
        case .translation: seconds = 120
        case .needsLanguages, .unavailable: seconds = 15
        }
        cache[key] = Cached(result: result, expires: Date().addingTimeInterval(seconds))
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > maxEntries { cache.removeValue(forKey: order.removeFirst()) }
    }

    private func startWorkers() {
        guard policy != .disabled, policy == .normal || optionDown else { return }
        if worker == nil, !queued.isEmpty { worker = Task { [weak self] in await self?.drainGlossary() } }
        if fallbackWorker == nil, !fallbackQueued.isEmpty {
            fallbackWorker = Task { [weak self] in await self?.drainFallback() }
        }
    }

    private func cancelWorkers() {
        worker?.cancel()
        fallbackWorker?.cancel()
    }

    private func drainGlossary() async {
        while !Task.isCancelled && !queued.isEmpty && policy != .disabled && (policy == .normal || optionDown) {
            let key = queued.removeFirst()
            inFlight = key
            let started = epoch
            let entry = await provider.glossary(key)
            if isCurrent(key, epoch: started) {
                if let entry {
                    remember(.translation(entry), for: key)
                    if optionDown { changed() }
                } else if fallbackInFlight != key && !fallbackQueued.contains(key) {
                    fallbackQueued.append(key)
                    startWorkers()
                }
            }
            inFlight = nil
            if !isCurrent(key, epoch: started) { requeueIfNeeded(key) }
        }
        worker = nil
        startWorkers()
    }

    private func drainFallback() async {
        while !Task.isCancelled && !fallbackQueued.isEmpty && policy != .disabled && (policy == .normal || optionDown) {
            let key = fallbackQueued.removeFirst()
            fallbackInFlight = key
            let started = epoch
            let result = await provider.translate(key)
            if isCurrent(key, epoch: started) {
                switch result {
                case .text(let text): remember(.translation(text), for: key)
                case .needsLanguages: remember(.needsLanguages, for: key)
                case .unavailable: remember(.unavailable, for: key)
                }
                if optionDown { changed() }
            }
            fallbackInFlight = nil
            if !isCurrent(key, epoch: started) { requeueIfNeeded(key) }
        }
        fallbackWorker = nil
        startWorkers()
    }

    private func requeueIfNeeded(_ key: CandidateLookupKey) {
        // A privacy change may have invalidated a request for a word that is
        // visible again. Ask for it afresh, without duplicating in-flight work.
        if page.contains(key), policy != .disabled, (policy == .normal || optionDown),
           key != inFlight, key != fallbackInFlight, cached(key) == nil,
           !queued.contains(key), !fallbackQueued.contains(key) { queued.insert(key, at: 0) }
    }

    private func isCurrent(_ key: CandidateLookupKey, epoch started: UInt64) -> Bool {
        epoch == started && page.contains(key) && policy != .disabled && (policy == .normal || optionDown)
    }
}

/// Reads the build-time TSV index without retaining it as a Swift dictionary.
/// All SQLite work is serial and off the typing thread, with a small page cache.
private final class GlossaryIndex: @unchecked Sendable {
    private let url: URL
    private let queue = DispatchQueue(label: "OctoDot.glossary", qos: .userInitiated)
    private var database: OpaquePointer?
    private var attemptedOpen = false

    init(url: URL) { self.url = url }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func lookup(_ key: CandidateLookupKey) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.read(key)) }
        }
    }

    private func read(_ key: CandidateLookupKey) -> String? {
        if !attemptedOpen {
            attemptedOpen = true
            var opened: OpaquePointer?
            if sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK {
                database = opened
                sqlite3_exec(opened, "PRAGMA query_only=ON; PRAGMA cache_size=-256", nil, nil, nil)
            } else if let opened { sqlite3_close(opened) }
        }
        guard let database else { return nil }
        let sql = key.language == .chinese
            ? "SELECT translation FROM zh WHERE term = ?1"
            : "SELECT translation FROM en WHERE term = ?1"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var term = key.text.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        if key.language == .english { term = term.lowercased() }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, term, -1, transient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else { return nil }
        return String(cString: value)
    }
}

/// The supplied glossary, then Apple's installed, on-device Translation
/// languages. Candidate lookups never request a language download.
@available(macOS 26.0, *)
@MainActor
final class SystemCandidateLookup: CandidateLookupProvider {
    private let index: GlossaryIndex
    private var availability: [CandidateLanguage: (LanguageAvailability.Status, Date)] = [:]
    private var sessions: [CandidateLanguage: TranslationSession] = [:]

    init(glossaryURL: URL) { index = GlossaryIndex(url: glossaryURL) }

    func glossary(_ key: CandidateLookupKey) async -> String? { await index.lookup(key).flatMap(Self.excerpt) }

    func translate(_ key: CandidateLookupKey) async -> MachineTranslation {
        let source = Locale.Language(identifier: key.language == .chinese ? "zh-Hans" : "en")
        let target = Locale.Language(identifier: key.language == .chinese ? "en" : "zh-Hans")
        let state: LanguageAvailability.Status
        if let cached = availability[key.language], cached.1 > Date() {
            state = cached.0
        } else {
            state = await LanguageAvailability().status(from: source, to: target)
            availability[key.language] = (state, Date().addingTimeInterval(state == .installed ? 60 : 15))
        }
        guard state == .installed else { return state == .supported ? .needsLanguages : .unavailable }
        let session: TranslationSession
        if let existing = sessions[key.language] {
            session = existing
        } else {
            if #available(macOS 26.4, *) {
                session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
            } else {
                session = TranslationSession(installedSource: source, target: target)
            }
            sessions[key.language] = session
        }
        do {
            let response = try await session.translate(key.text)
            guard let text = Self.excerpt(response.targetText) else { return .unavailable }
            return .text(text)
        } catch {
            // A language can be removed after the availability check.
            sessions.removeValue(forKey: key.language)
            availability.removeValue(forKey: key.language)
            return .unavailable
        }
    }

    nonisolated private static func excerpt(_ text: String) -> String? {
        let compact = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        var excerpt = String(compact.prefix(160))
        while excerpt.utf8.count > 512 { excerpt.removeLast() }
        return excerpt
    }
}
