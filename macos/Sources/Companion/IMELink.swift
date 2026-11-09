import AppKit

/// Asking the installed input method for things it owns (its settings live
/// in it, by the running engine): distributed notifications, which a
/// sandboxed app may post as long as they carry no data, so the data is in
/// the name. The IME listens (Sources/IME/Companion.swift).
@MainActor
enum IMELink {
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: Identity.ime).isEmpty }

    /// Shows the IME's settings window, starting the IME first if it is not
    /// running (as macOS would on selecting it).
    static func showSettings() {
        ensureRunning { post("showSettings") }
    }

    /// The scheme the IME types in (fullpinyin, flypy).
    static func useScheme(_ id: String) { ensureRunning { post("scheme." + id) } }

    /// The full character set, or the daily one.
    static func useFullCharset(_ on: Bool) { ensureRunning { post(on ? "charset.full" : "charset.daily") } }

    /// The grammar model is in the shared folder now: a running IME turns it
    /// on (a new core, loaded by an install, opens it by itself). Not started for it.
    static func grammarReady() { post("grammar.reopen") }

    private static func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Identity.ime + "." + name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    /// Not through NSWorkspace: the app that opens the IME becomes its
    /// parent, and macOS 27 then keeps this app in the Dock, "Running in
    /// Background", for as long as the IME runs. The installer opens it as
    /// /usr/bin/open does, with no parent.
    private static func ensureRunning(then action: @escaping @MainActor () -> Void) {
        if isRunning {
            action()
            return
        }
        Task { @MainActor in
            guard await InstallerClient.shared.launchIME() else { return }
            // The IME listens once its core has started: a moment after launch.
            try? await Task.sleep(for: .seconds(1))
            action()
        }
    }
}
