import CoreServices
import Foundation
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
    /// Dictionary Services returns an unstructured entry, not necessarily a translation.
    case dictionary(String)
    case needsLanguages
    case unavailable

    var caption: String {
        switch self {
        case .translation(let text): text
        case .dictionary(let text): "词典: " + text
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

private enum LookupPart: Sendable {
    case dictionary(String?)
    case machine(MachineTranslation)
}

/// A fake provider can control timing and replies in the typing tests.
@MainActor
protocol CandidateLookupProvider: AnyObject, Sendable {
    func dictionary(_ text: String) async -> String?
    func translate(_ key: CandidateLookupKey) async -> MachineTranslation
}

/// One serial, replaceable queue for the visible page. A synchronous system
/// dictionary call cannot be interrupted, so it is allowed to finish, but
/// older pages never build up a backlog or update a newer page.
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
            queued.removeAll()
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
        queued = priority.filter { $0 != inFlight && cached($0) == nil }
        if policy == .normal || optionDown { startWorker() }
    }

    func setOptionDown(_ down: Bool) {
        guard optionDown != down else { return }
        optionDown = down
        if policy == .incognito && !down {
            epoch &+= 1
            queued.removeAll()
            cache.removeAll()
            order.removeAll()
        } else if down {
            // An incognito page is not prefetched; make its requests now.
            queued = priority.filter { $0 != inFlight && cached($0) == nil }
            startWorker()
        }
    }

    func captions() -> [String] {
        page.map { key in
            guard let key else { return "—" }
            return cached(key)?.caption ?? "…"
        }
    }

    /// What replaces each candidate while Option is held. Empty until there is
    /// a translation, a dictionary excerpt, or the missing-language notice.
    func replacements() -> [String] {
        page.map { key in
            guard let key, let result = cached(key) else { return "" }
            switch result {
            case .translation, .dictionary, .needsLanguages: return result.caption
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

    /// Drop both retained results and pending work. A live dictionary call is
    /// not cancellable; epoch makes its eventual answer harmless.
    func clear() {
        epoch &+= 1
        page.removeAll()
        priority.removeAll()
        queued.removeAll()
        cache.removeAll()
        order.removeAll()
        policy = .disabled
        optionDown = false
    }

    private func cached(_ key: CandidateLookupKey) -> CandidateLookupResult? {
        guard let item = cache[key] else { return nil }
        if item.expires <= Date() { cache.removeValue(forKey: key); order.removeAll { $0 == key }; return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return item.result
    }

    private func remember(_ result: CandidateLookupResult, for key: CandidateLookupKey) {
        let seconds: TimeInterval
        switch result {
        case .translation, .dictionary: seconds = 120
        case .needsLanguages, .unavailable: seconds = 15
        }
        cache[key] = Cached(result: result, expires: Date().addingTimeInterval(seconds))
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > maxEntries { cache.removeValue(forKey: order.removeFirst()) }
    }

    private func startWorker() {
        guard worker == nil, !queued.isEmpty, policy != .disabled, policy == .normal || optionDown else { return }
        worker = Task { [weak self] in await self?.drain() }
    }

    private func drain() async {
        while !queued.isEmpty && policy != .disabled && (policy == .normal || optionDown) {
            let key = queued.removeFirst()
            inFlight = key
            let started = epoch
            let provider = self.provider
            await withTaskGroup(of: LookupPart.self) { group in
                group.addTask { .dictionary(await provider.dictionary(key.text)) }
                group.addTask { .machine(await provider.translate(key)) }
                var entry: String?
                var dictionaryFinished = false
                var machine: MachineTranslation?
                for await part in group {
                    switch part {
                    case .dictionary(let value): entry = value; dictionaryFinished = true
                    case .machine(let value): machine = value
                    }
                    guard epoch == started, page.contains(key), policy != .disabled,
                          policy == .normal || optionDown else { continue }
                    let result: CandidateLookupResult?
                    switch machine {
                    case .text(let text): result = .translation(text)
                    case .needsLanguages: result = entry.map { .dictionary($0) } ?? .needsLanguages
                    case .unavailable: result = entry.map { .dictionary($0) } ?? (dictionaryFinished ? .unavailable : nil)
                    case nil: result = entry.map { .dictionary($0) }
                    }
                    if let result {
                        remember(result, for: key)
                        if optionDown { changed() }
                    }
                }
            }
            inFlight = nil
            guard epoch == started, page.contains(key), policy != .disabled,
                  policy == .normal || optionDown else {
                // A privacy change may have invalidated an in-flight request
                // for a word that is visible again. Ask for it afresh.
                if page.contains(key), policy != .disabled, (policy == .normal || optionDown),
                   cached(key) == nil, !queued.contains(key) { queued.insert(key, at: 0) }
                continue
            }
        }
        worker = nil
        // A page may have arrived while a stale request was finishing.
        startWorker()
    }
}

/// Apple Dictionary and its installed, on-device Translation languages. The
/// latter never requests a download from the candidate window.
@available(macOS 26.0, *)
@MainActor
final class SystemCandidateLookup: CandidateLookupProvider {
    private let dictionaryQueue = DispatchQueue(label: "OctoDot.dictionary", qos: .userInitiated)
    private var availability: [CandidateLanguage: (LanguageAvailability.Status, Date)] = [:]
    private var sessions: [CandidateLanguage: TranslationSession] = [:]

    func dictionary(_ text: String) async -> String? {
        await withCheckedContinuation { continuation in
            dictionaryQueue.async {
                let result: String? = autoreleasepool {
                    let source = text as CFString
                    guard let value = DCSCopyTextDefinition(nil, source, CFRange(location: 0, length: CFStringGetLength(source)))?
                        .takeRetainedValue() as String? else { return nil }
                    return Self.excerpt(value)
                }
                continuation.resume(returning: result)
            }
        }
    }

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
        return String(compact.prefix(160))
    }
}
