import AppKit
import Foundation

/// What the companion shows, driven by SetupState (Sources/Setup): the
/// wizard's steps for a new or old install, or the home screen once the
/// input method is installed, current and enabled.
@MainActor
@Observable
final class SetupModel {
    enum Step: Int, CaseIterable, Comparable {
        case location, install, privacy, tryIt
        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    enum Screen: Equatable { case loading, wizard, home }

    var screen = Screen.loading {
        didSet { if screen != .wizard { stopPolling() } }
    }
    var step = Step.install {
        didSet { if step != .install { stopPolling() } }
    }
    var facts: SetupFacts?
    var state: SetupState?
    /// Working on something (a button shows progress).
    var busy = false
    /// The last thing to tell the user, and whether it went wrong.
    var message: String?
    var failed = false
    /// Step B: the input source is enabled; and whether to point at System Settings.
    var enabled = false
    var showSettingsHelp = false
    var preflight: Preflight?
    var scheme = "fullpinyin"
    var fullCharset = false
    /// The grammar model's download, while there is one: the share done.
    var grammarProgress: Double?
    var canCancelOnboardingAction = false

    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var onboardingAction: Task<Void, Never>?
    @ObservationIgnored private var grammarRequest: UUID?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var installedForEnable = false

    deinit { poll?.cancel() }

    /// Steps this install goes through (the location step only when needed).
    var steps: [Step] { (state == .wrongLocation ? [.location] : []) + [.install, .privacy, .tryIt] }

    /// Looks at the Mac and decides: an outdated input method is brought up
    /// to date in place. Once the input method is ready, show the home screen.
    func refresh() async {
        guard !refreshing, !busy, onboardingAction == nil else { return }
        refreshing = true
        defer { refreshing = false }
        await refresh(installIfOutdated: true)
    }

    private func refresh(installIfOutdated: Bool) async {
        let facts = await InstallerClient.shared.facts()
        guard !Task.isCancelled else { return }
        guard let facts else {
            screen = .wizard
            report(false, "OctoDot 的安装程序没有响应。请从磁盘映像重新安装 OctoDot。")
            return
        }
        self.facts = facts
        let state = SetupState.of(facts)
        self.state = state
        if state != .disabled { installedForEnable = false }
        enabled = facts.enabled
        switch state {
        case .wrongLocation:
            step = .location
            screen = .wizard
        case .notInstalled:
            step = .install
            screen = .wizard
        case .disabled:
            step = .install
            screen = .wizard
        case .outdated:
            guard installIfOutdated else {
                screen = .home
                return
            }
            busy = true
            let (ok, text, note) = await installWithGrammar()
            busy = false
            guard !Task.isCancelled else { return }
            report(ok && note == nil, [text, note].compactMap { $0 }.joined(separator: " "))
            if ok { await refresh(installIfOutdated: false) } else { screen = .home }
        case .ready:
            screen = .home
            if GrammarStore.isMissing {
                let note = await placeGrammar()
                guard !Task.isCancelled else { return }
                if let note { report(false, note) } else { IMELink.grammarReady() }
            }
        }
    }

    // MARK: The grammar model

    /// The grammar model into the shared folder (GrammarStore), before the
    /// input method that wants it is installed: copied from this app, or
    /// downloaded, its progress shown. nil, or what to tell the user: the
    /// input method types without the model, less accurately, until it is there.
    func placeGrammar() async -> String? {
        let id = UUID()
        grammarRequest = id
        defer {
            grammarRequest = nil
            grammarProgress = nil
        }
        do {
            try await GrammarStore.ensure { [weak self] share in
                Task { @MainActor in
                    if let self, self.grammarRequest == id { self.grammarProgress = share }
                }
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            return "语法模型未能就位（\(error)）。在你再次打开 OctoDot 之前，输入仍可使用，但准确度会低一些。"
        }
    }

    /// The model, then the input method; once that is installed, the models
    /// it no longer wants go. The installer's answer, and a note if the model
    /// is not in place.
    private func installWithGrammar() async -> (Bool, String, String?) {
        let note = await placeGrammar()
        guard !Task.isCancelled else { return (false, Outcome.cancelled.message, nil) }
        let (ok, text) = await InstallerClient.shared.installIME()
        if ok {
            GrammarStore.prune()
            if note == nil { IMELink.grammarReady() }
        }
        return (ok, text, note)
    }

    func runOnboardingAction(_ action: @escaping @MainActor (SetupModel) async -> Void) {
        guard onboardingAction == nil, !busy, !refreshing else { return }
        canCancelOnboardingAction = true
        onboardingAction = Task { [weak self] in
            guard let self else { return }
            defer {
                self.onboardingAction = nil
                self.canCancelOnboardingAction = false
            }
            await action(self)
        }
    }

    func stopOnboarding() {
        stopPolling()
        cancelOnboardingAction()
    }

    func cancelOnboardingAction() {
        canCancelOnboardingAction = false
        onboardingAction?.cancel()
    }

    // MARK: Step A: location

    func moveToApplications() async {
        busy = true
        let (ok, path) = await InstallerClient.shared.copyToApplications()
        busy = false
        if Task.isCancelled, path == Outcome.cancelled.message { return }
        guard ok else { return report(false, path) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Step B: install and enable

    /// Installs, registers and enables; then waits for the source to be
    /// enabled (macOS may want the user to switch it on in System Settings),
    /// and moves on the moment it is.
    func install() async {
        stopPolling()
        busy = true
        defer { busy = false }
        if !installedForEnable {
            let (ok, text, note) = await installWithGrammar()
            if Task.isCancelled, text == Outcome.cancelled.message { return }
            guard ok else { return report(false, text) }
            installedForEnable = true
            report(note == nil, [text, note].compactMap { $0 }.joined(separator: " "))
        }
        guard !Task.isCancelled, screen == .wizard, step == .install else { return }
        let outcome = await InstallerClient.shared.enableIME()
        if !outcome.message.isEmpty, outcome != .cancelled { report(false, outcome.message) }
        guard !Task.isCancelled, screen == .wizard, step == .install else { return }
        if outcome.ok {
            enabled = true
            step = .privacy
        } else {
            startPolling()
        }
    }

    private func startPolling() {
        guard poll == nil else { return }
        poll = Task { [weak self] in
            let started = ContinuousClock.now
            while !Task.isCancelled {
                if ContinuousClock.now - started > .milliseconds(1500) { self?.showSettingsHelp = true }
                let enabled = await InstallerClient.shared.isEnabled()
                guard !Task.isCancelled, let self else { return }
                if enabled {
                    self.enabled = true
                    self.step = .privacy
                    return
                }
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            }
        }
    }

    private func stopPolling() {
        poll?.cancel()
        poll = nil
        showSettingsHelp = false
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Step C: privacy and pre-flight

    func runPreflight() async {
        busy = true
        let result = await InstallerClient.shared.preflight()
        busy = false
        guard !Task.isCancelled else { return }
        preflight = result
        if preflight == nil { report(false, "输入法检查没有运行。") }
    }

    // MARK: Step D: try it

    struct Scheme {
        let id: String
        let name: String
    }

    let schemes: [Scheme] = {
        let defaultScheme = Scheme(id: "fullpinyin", name: "全拼")
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("OctoDotIME.app/Contents/Resources/data/schemes.tsv"),
              let table = try? String(contentsOf: url, encoding: .utf8) else { return [defaultScheme] }
        let doublePinyin = table.split(separator: "\n").compactMap { line -> Scheme? in
            let fields = line.split(separator: "\t")
            guard fields.count == 2, fields[0] != defaultScheme.id else { return nil }
            return Scheme(id: String(fields[0]), name: String(fields[1]))
        }
        return [defaultScheme] + doublePinyin
    }()

    func selectIME() { Task { _ = await InstallerClient.shared.selectIME() } }
    func useScheme(_ id: String) {
        scheme = id
        IMELink.useScheme(id)
    }
    func useFullCharset(_ on: Bool) {
        fullCharset = on
        IMELink.useFullCharset(on)
    }

    func finish() {
        stopOnboarding()
        screen = .home
        message = nil
    }

    func next() {
        let all = steps
        if let i = all.firstIndex(of: step), i + 1 < all.count { step = all[i + 1] }
    }

    private func report(_ ok: Bool, _ text: String) {
        failed = !ok
        message = text
    }
}
