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

    var screen = Screen.loading
    var step = Step.install
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

    private var poll: Timer?
    private var placingGrammar = false

    /// Steps this install goes through (the location step only when needed).
    var steps: [Step] { (state == .wrongLocation ? [.location] : []) + [.install, .privacy, .tryIt] }

    /// Looks at the Mac and decides: an outdated input method is brought up
    /// to date in place. Once the input method is ready, show the home screen.
    func refresh() async {
        guard let facts = await InstallerClient.shared.facts() else {
            screen = .wizard
            report(false, "OctoDot 的安装程序没有响应。请从磁盘映像重新安装 OctoDot。")
            return
        }
        self.facts = facts
        let state = SetupState.of(facts)
        self.state = state
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
            busy = true
            let (ok, text, note) = await installWithGrammar()
            busy = false
            report(ok && note == nil, [text, note].compactMap { $0 }.joined(separator: " "))
            if ok { await refresh() } else { screen = .home }
        case .ready:
            screen = .home
            if GrammarStore.isMissing {
                if let note = await placeGrammar() { report(false, note) } else { IMELink.grammarReady() }
            }
        }
    }

    // MARK: The grammar model

    /// The grammar model into the shared folder (GrammarStore), before the
    /// input method that wants it is installed: copied from this app, or
    /// downloaded, its progress shown. nil, or what to tell the user: the
    /// input method types without the model, less accurately, until it is there.
    func placeGrammar() async -> String? {
        placingGrammar = true
        defer {
            placingGrammar = false
            grammarProgress = nil
        }
        do {
            try await GrammarStore.ensure { [weak self] share in
                Task { @MainActor in
                    if let self, self.placingGrammar { self.grammarProgress = share }
                }
            }
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
        let (ok, text) = await InstallerClient.shared.installIME()
        if ok {
            GrammarStore.prune()
            if note == nil { IMELink.grammarReady() }
        }
        return (ok, text, note)
    }

    // MARK: Step A: location

    func moveToApplications() async {
        busy = true
        let (ok, path) = await InstallerClient.shared.copyToApplications()
        busy = false
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
        busy = true
        let (ok, text, note) = await installWithGrammar()
        guard ok else {
            busy = false
            return report(false, text)
        }
        report(note == nil, [text, note].compactMap { $0 }.joined(separator: " "))
        enabled = await InstallerClient.shared.enableIME()
        busy = false
        if enabled { return step = .privacy }
        startPolling()
    }

    private func startPolling() {
        poll?.invalidate()
        let started = Date()
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Date().timeIntervalSince(started) > 1.5 { self.showSettingsHelp = true }
                Task { @MainActor in
                    guard await InstallerClient.shared.isEnabled() else { return }
                    self.poll?.invalidate()
                    self.poll = nil
                    self.enabled = true
                    self.showSettingsHelp = false
                    if self.step == .install { self.step = .privacy }
                }
            }
        }
    }

    func openKeyboardSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Step C: privacy and pre-flight

    func runPreflight() async {
        busy = true
        preflight = await InstallerClient.shared.preflight()
        busy = false
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
