import AppKit

/// Asking the installed input method for things it owns (its settings live
/// in it, by the running engine): distributed notifications, which a
/// sandboxed app may post as long as they carry no data, so the data is in
/// the name. The IME listens (Sources/IME/Companion.swift).
@MainActor
enum IMELink {
    /// The user's real home: inside the sandbox, the home directory is the
    /// companion's container.
    static var home: URL {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: dir))
    }

    static var installedIME: URL { home.appendingPathComponent("Library/Input Methods/OctoDotIME.app") }

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

    private static func post(_ name: String) {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Identity.ime + "." + name), object: nil, userInfo: nil, deliverImmediately: true)
    }

    private static func ensureRunning(then action: @escaping @MainActor () -> Void) {
        if isRunning {
            action()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: installedIME, configuration: configuration) { _, _ in
            // The IME listens once its core has started: a moment after launch.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { MainActor.assumeIsolated { action() } }
        }
    }
}
