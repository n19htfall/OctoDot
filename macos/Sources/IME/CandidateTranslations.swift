import Foundation
import SQLite3
@preconcurrency import Translation

/// The privacy policy for candidate lookups. Incognito requires an explicit
/// translation-key hold and keeps no results after it ends.
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
    /// Each occupied slot has its own session; it is not reused until the call returns.
    func translate(_ key: CandidateLookupKey, slot: Int) async -> MachineTranslation
    func cancelTranslation(in slot: Int)
}

/// Replaceable queues for the visible page. The fast glossary can make
/// progress independently of system translation. One obsolete translation can
/// finish beside the current page's request, without growing an unbounded queue.
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
    private struct FallbackFlight {
        let key: CandidateLookupKey
        let epoch: UInt64
        let task: Task<Void, Never>
    }
    private var fallbackFlights: [Int: FallbackFlight] = [:]
    private var prefetchTask: Task<Void, Never>?
    private var prefetchReady = false
    private let prefetchDelay: UInt64
    private var epoch: UInt64 = 0
    private var policy: CandidateLookupPolicy = .disabled
    private var translationHeld = false
    private let changed: @MainActor () -> Void
    private let maxEntries = 128

    init(provider: any CandidateLookupProvider, prefetchDelay: UInt64 = 120_000_000,
         changed: @escaping @MainActor () -> Void) {
        self.provider = provider
        self.prefetchDelay = prefetchDelay
        self.changed = changed
    }

    static var supported: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    func setPage(_ candidates: [String], highlighted: Int, policy: CandidateLookupPolicy) {
        let oldPage = page
        let oldPriority = priority
        let policyChanged = self.policy != policy
        if policyChanged {
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
            queued.removeAll()
            fallbackQueued.removeAll()
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
            $0 != inFlight && !isTranslating($0) && !fallbackQueued.contains($0) && cached($0) == nil
        }
        if policyChanged || oldPage != page || oldPriority != priority { resetPrefetch() }
        if policy == .normal || translationHeld { startWorkers() }
    }

    func setTranslationHeld(_ down: Bool) {
        guard translationHeld != down else { return }
        translationHeld = down
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
                $0 != inFlight && !isTranslating($0) && !fallbackQueued.contains($0) && cached($0) == nil
            }
        }
        resetPrefetch()
        startWorkers()
    }

    func captions() -> [String] {
        page.map { key in
            guard let key else { return "—" }
            return cached(key)?.caption ?? "…"
        }
    }

    /// What replaces each candidate while the translation key is held. Empty until there is
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
        translationHeld = false
    }

    /// Keep visible replacements usable while the translation key is held. Otherwise the
    /// next hold can repopulate the small cache from the current page.
    func trim() {
        guard !translationHeld else { return }
        cache.removeAll()
        order.removeAll()
    }

    private func cached(_ key: CandidateLookupKey) -> CandidateLookupResult? {
        guard let item = cache[key] else { return nil }
        // Do not let a visible replacement expire while it can be selected.
        if item.expires <= Date() && !(translationHeld && page.contains(key)) {
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
        guard policy != .disabled, policy == .normal || translationHeld else { return }
        if worker == nil, !queued.isEmpty { worker = Task { [weak self] in await self?.drainGlossary() } }
        startFallback()
    }

    private func resetPrefetch() {
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchReady = false
        guard policy == .normal, !translationHeld, !priority.isEmpty else { return }
        let delay = prefetchDelay
        prefetchTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard !Task.isCancelled, let self else { return }
            self.prefetchTask = nil
            self.prefetchReady = true
            self.startWorkers()
        }
    }

    private func isTranslating(_ key: CandidateLookupKey) -> Bool {
        fallbackFlights.values.contains { $0.key == key && $0.epoch == epoch && !$0.task.isCancelled }
    }

    private func startFallback() {
        guard translationHeld || prefetchReady else { return }
        // Keep normal prefetch to the highlighted candidate. Holding the translation key requests
        // the whole page, in highlight order, without the typing debounce.
        guard let key = priority.first(where: {
            (translationHeld || $0 == priority.first) && fallbackQueued.contains($0)
                && !isTranslating($0) && cached($0) == nil
        }) else { return }
        // Only one request for this page at a time. The second slot lets a
        // new page proceed while an old request finishes for the normal cache.
        guard !fallbackFlights.values.contains(where: {
            $0.epoch == epoch && !$0.task.isCancelled && page.contains($0.key)
        }) else { return }
        guard let slot = (0..<2).first(where: { fallbackFlights[$0] == nil }) else {
            // Cancellation is cooperative: retain occupied slots until their
            // calls return, even when a provider is slow to acknowledge it.
            for (slot, flight) in fallbackFlights where !flight.task.isCancelled {
                flight.task.cancel()
                provider.cancelTranslation(in: slot)
            }
            return
        }
        fallbackQueued.removeAll { $0 == key }
        let started = epoch
        let task = Task<Void, Never> { [weak self] in await self?.translate(key, slot: slot, epoch: started) }
        fallbackFlights[slot] = FallbackFlight(key: key, epoch: started, task: task)
    }

    private func cancelWorkers() {
        worker?.cancel()
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchReady = false
        for (slot, flight) in fallbackFlights where !flight.task.isCancelled {
            flight.task.cancel()
            provider.cancelTranslation(in: slot)
        }
    }

    private func drainGlossary() async {
        while !Task.isCancelled && !queued.isEmpty && policy != .disabled && (policy == .normal || translationHeld) {
            let key = queued.removeFirst()
            inFlight = key
            let started = epoch
            let entry = await provider.glossary(key)
            if let entry, canRemember(key, epoch: started) {
                remember(.translation(entry), for: key)
                if translationHeld && isCurrent(key, epoch: started) { changed() }
            } else if entry == nil, isCurrent(key, epoch: started),
                      !isTranslating(key), !fallbackQueued.contains(key) {
                fallbackQueued.append(key)
                startWorkers()
            }
            inFlight = nil
            if !isCurrent(key, epoch: started) { requeueIfNeeded(key) }
        }
        worker = nil
        startWorkers()
    }

    private func translate(_ key: CandidateLookupKey, slot: Int, epoch started: UInt64) async {
        let result: MachineTranslation = Task.isCancelled ? .unavailable : await provider.translate(key, slot: slot)
        let current = isCurrent(key, epoch: started)
        var remembered = false
        if canRemember(key, epoch: started) {
            switch result {
            case .text(let text):
                remember(.translation(text), for: key)
                remembered = true
            case .needsLanguages where current && !Task.isCancelled:
                remember(.needsLanguages, for: key)
                remembered = true
            case .unavailable where current && !Task.isCancelled:
                remember(.unavailable, for: key)
                remembered = true
            default: break
            }
        }
        if remembered && current && translationHeld { changed() }
        fallbackFlights[slot] = nil
        requeueIfNeeded(key)
        startWorkers()
    }

    private func requeueIfNeeded(_ key: CandidateLookupKey) {
        // A privacy change may have invalidated a request for a word that is
        // visible again. Ask for it afresh, without duplicating in-flight work.
        if page.contains(key), policy != .disabled, (policy == .normal || translationHeld),
           key != inFlight, !isTranslating(key), cached(key) == nil,
           !queued.contains(key), !fallbackQueued.contains(key) { queued.insert(key, at: 0) }
    }

    private func isCurrent(_ key: CandidateLookupKey, epoch started: UInt64) -> Bool {
        epoch == started && page.contains(key) && policy != .disabled && (policy == .normal || translationHeld)
    }

    private func canRemember(_ key: CandidateLookupKey, epoch started: UInt64) -> Bool {
        epoch == started && (policy == .normal || isCurrent(key, epoch: started))
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
    // Preserve both language directions in each of the two slots, so mixed
    // candidate pages do not rebuild a session every time the language changes.
    private var sessions: [Int: [CandidateLanguage: TranslationSession]] = [:]

    init(glossaryURL: URL) { index = GlossaryIndex(url: glossaryURL) }

    func glossary(_ key: CandidateLookupKey) async -> String? { await index.lookup(key).flatMap(Self.excerpt) }

    func cancelTranslation(in slot: Int) {
        guard let cancelled = sessions.removeValue(forKey: slot) else { return }
        for session in cancelled.values { session.cancel() }
    }

    func translate(_ key: CandidateLookupKey, slot: Int) async -> MachineTranslation {
        guard !Task.isCancelled else { return .unavailable }
        let source = Locale.Language(identifier: key.language == .chinese ? "zh-Hans" : "en")
        let target = Locale.Language(identifier: key.language == .chinese ? "en" : "zh-Hans")
        let state: LanguageAvailability.Status
        if let cached = availability[key.language], cached.1 > Date() {
            state = cached.0
        } else {
            // SDK 26.4+ defaults this check to Apple Intelligence models, a
            // different family from the low-latency session created below.
            if #available(macOS 26.4, *) {
                state = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
            } else {
                state = await LanguageAvailability().status(from: source, to: target)
            }
            guard !Task.isCancelled else { return .unavailable }
            availability[key.language] = (state, Date().addingTimeInterval(state == .installed ? 60 : 15))
        }
        guard state == .installed else { return state == .supported ? .needsLanguages : .unavailable }
        let session: TranslationSession
        if let existing = sessions[slot]?[key.language] {
            session = existing
        } else {
            if #available(macOS 26.4, *) {
                session = TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
            } else {
                session = TranslationSession(installedSource: source, target: target)
            }
            sessions[slot, default: [:]][key.language] = session
        }
        do {
            let response = try await session.translate(key.text)
            guard let text = Self.excerpt(response.targetText) else { return .unavailable }
            return .text(text)
        } catch {
            guard !Task.isCancelled else { return .unavailable }
            // A language can be removed after the availability check.
            if sessions[slot]?[key.language] === session { sessions[slot]?[key.language] = nil }
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
