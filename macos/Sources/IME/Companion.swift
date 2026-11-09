import AppKit

/// The IME's side of the companion app (/Applications/OctoDot.app,
/// docs/distribution-and-onboarding.md): the companion asks it to show its
/// settings window (Settings live here, by the running engine), and the
/// input menu opens the companion for what the IME may not do, such as
/// checking for updates (the IME has no network).
@MainActor
enum Companion {
    private static var observer: SettingsObserver?

    /// Listens for the companion (distributed notifications, which a
    /// sandboxed app may post as long as they carry no data, so the request
    /// is in the name): "show the settings", and the onboarding's scheme and
    /// character set. Only while this core runs: a newer core, loaded in
    /// place, listens instead.
    static func start() {
        let observer = SettingsObserver()
        let center = DistributedNotificationCenter.default()
        var names = ["showSettings", "charset.full", "charset.daily"]
        names += Engine.shared.schemes().map { "scheme." + $0.id }
        for name in names {
            center.addObserver(observer, selector: #selector(SettingsObserver.request(_:)),
                               name: Notification.Name(Identity.ime + "." + name), object: nil,
                               suspensionBehavior: .deliverImmediately)
        }
        Self.observer = observer
    }

    fileprivate static func handle(_ request: String) {
        switch request {
        case "showSettings": SettingsWindow.show()
        case "charset.full": Learning.useFullCharset(true)
        case "charset.daily": Learning.useFullCharset(false)
        default:
            if request.hasPrefix("scheme.") { Learning.useScheme(String(request.dropFirst("scheme.".count))) }
        }
    }

    static func stop() {
        if let observer { DistributedNotificationCenter.default().removeObserver(observer) }
        observer = nil
    }

    /// Opens the companion at `path` of its URL scheme (octodot://update,
    /// octodot://setup). The sandbox lets an app open a URL; the companion
    /// does the rest.
    static func open(_ path: String) {
        if let url = URL(string: "\(Identity.urlScheme)://\(path)") { NSWorkspace.shared.open(url) }
    }
}

/// A selector observer, because only that form takes a suspension behavior:
/// an input method is never the active app, and AppKit holds distributed
/// notifications back from inactive apps.
private final class SettingsObserver: NSObject {
    @objc func request(_ note: Notification) {
        let request = String(note.name.rawValue.dropFirst(Identity.ime.count + 1))
        MainActor.assumeIsolated { Companion.handle(request) }
    }
}
