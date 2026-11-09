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

    private var poll: Timer?

    /// Steps this install goes through (the location step only when needed).
    var steps: [Step] { (state == .wrongLocation ? [.location] : []) + [.install, .privacy, .tryIt] }

    /// Looks at the Mac and decides: an outdated input method is brought up
    /// to date at once (in place, apps keep typing); a ready one goes
    /// straight to its settings.
    func refresh(openSettingsWhenReady: Bool = false) async {
        guard let facts = await InstallerClient.shared.facts() else {
            screen = .wizard
            report(false, "OctoDot's installer did not answer. Reinstall OctoDot from its disk image.")
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
            let (ok, text) = await InstallerClient.shared.installIME()
            busy = false
            report(ok, text)
            if ok { await refresh(openSettingsWhenReady: openSettingsWhenReady) } else { screen = .home }
        case .ready:
            screen = .home
            if openSettingsWhenReady { IMELink.showSettings() }
        }
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
        let (ok, text) = await InstallerClient.shared.installIME()
        guard ok else {
            busy = false
            return report(false, text)
        }
        report(true, text)
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
        if preflight == nil { report(false, "The input method's check did not run.") }
    }

    // MARK: Step D: try it

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
