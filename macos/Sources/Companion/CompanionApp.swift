import AppKit
import SwiftUI

/// OctoDot.app, the companion (docs/distribution-and-onboarding.md): what the
/// user drags to Applications and opens. It installs the input method it
/// carries, keeps it up to date, and removes it; the input method's settings
/// stay in the input method, which this opens.
struct CompanionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("OctoDot", id: "main") {
            RootView(model: delegate.model, updater: delegate.updater)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { delegate.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}

struct RootView: View {
    @Bindable var model: SetupModel
    @Bindable var updater: Updater

    var body: some View {
        switch model.screen {
        case .loading:
            Group {
                if let share = model.grammarProgress {
                    GrammarDownload(share: share).frame(width: 360)
                } else {
                    ProgressView("正在查看这台 Mac…")
                }
            }
            .frame(width: 620, height: 500)
        case .wizard:
            OnboardingView(model: model)
        case .home:
            HomeView(model: model, updater: updater)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = SetupModel()
    let updater = Updater()

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await model.refresh() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// octodot://update (the input method's "Check for Updates…"),
    /// octodot://settings, octodot://setup.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: text), url.scheme == Identity.urlScheme else { return }
        switch url.host {
        case "update": checkForUpdates()
        case "settings": IMELink.showSettings()
        case "setup":
            Task {
                await model.refresh()
                model.screen = .wizard
            }
        case "pick-app":
            // The panel is modal. Afterwards the settings window comes forward,
            // so this app does not take focus back.
            AppPicker.pick()
            return
        default: break
        }
        NSApp.activate()
    }

    func checkForUpdates() {
        NSApp.activate()
        Task {
            if model.screen == .loading { await model.refresh() }
            if model.screen == .wizard && model.state == .ready { model.screen = .home }
            await updater.check(interactive: true)
        }
    }
}
