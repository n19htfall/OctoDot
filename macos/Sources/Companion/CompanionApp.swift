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
                Button("Check for Updates…") { delegate.checkForUpdates() }
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
            ProgressView("Looking at this Mac…").frame(width: 620, height: 500)
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
    /// A link opened the app (octodot://…): it says what to do, not the launch.
    private var openedForURL = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            // A moment for a launch link to arrive first.
            try? await Task.sleep(for: .milliseconds(200))
            await model.refresh(openSettingsWhenReady: !openedForURL)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// octodot://update (the input method's "Check for Updates…"),
    /// octodot://settings, octodot://setup.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        openedForURL = true
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
        default: break
        }
        NSApp.activate()
    }

    func checkForUpdates() {
        NSApp.activate()
        Task {
            if model.screen == .loading { await model.refresh() }
            if model.screen == .wizard && model.state == .ready { model.screen = .home }
            await updater.check()
        }
    }
}
