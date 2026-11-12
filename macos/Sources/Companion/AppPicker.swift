import AppKit
import UniformTypeIdentifiers

/// The companion has the user-selected file entitlement, and the input method
/// does not, so the panel opens here. It reads the bundle id and the display
/// name, drops the file access, and hands those two strings to the settings window.
@MainActor
enum AppPicker {
    private static var picking = false

    static func pick() {
        guard !picking else { return }
        picking = true
        defer { picking = false }
        AppPick.discard()
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "添加应用"
        panel.prompt = "添加"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if panel.runModal() == .OK, let url = panel.url, let choice = metadata(of: url) {
            AppPick.write(choice)
        }
        IMELink.appPicked()
    }

    /// The bundle id and the name Finder shows. The security scope ends before return.
    private static func metadata(of url: URL) -> AppPick.Choice? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let bundle = Bundle(url: url),
              let id = AppRulesDocument.bundleID(bundle.bundleIdentifier ?? "") else { return nil }
        return AppPick.Choice(id: id, name: AppRulesDocument.displayName(FileManager.default.displayName(atPath: url.path), id: id))
    }
}
