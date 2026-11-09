import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Once the input method is set up: what is installed, its settings,
/// updates, backups, and uninstalling.
struct HomeView: View {
    @Bindable var model: SetupModel
    @Bindable var updater: Updater
    @State private var uninstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("OctoDot").font(.largeTitle.weight(.semibold))
                    Text(versionLine).foregroundStyle(.secondary)
                }
            }
            Card {
                Label(model.enabled ? "The input method is installed and among your input sources."
                                    : "The input method is installed, but not among your input sources.",
                      systemImage: model.enabled ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.enabled ? Color.green : Color.orange)
                HStack {
                    Button("Open Settings…") { IMELink.showSettings() }.buttonStyle(.borderedProminent)
                    if !model.enabled { Button("Set Up…") { model.screen = .wizard; model.step = .install } }
                }
            }
            Card {
                UpdateRow(updater: updater)
                Toggle("Check for updates automatically", isOn: $updater.automatic)
                Text("Only this app checks, over HTTPS, for releases signed with OctoDot's key. The input method itself never uses the network.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let share = model.grammarProgress { GrammarDownload(share: share) }
            if let message = model.message {
                Label(message, systemImage: model.failed ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(model.failed ? .orange : .secondary).font(.callout).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Button("Restore a Backup…") { restore() }
                Spacer()
                Button("Uninstall OctoDot…", role: .destructive) { uninstalling = true }
            }
        }
        .padding(28)
        .frame(width: 620, height: 500)
        .sheet(isPresented: $uninstalling) { UninstallSheet(model: model) }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let app = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        guard let ime = model.facts?.installed else { return "Version \(app)" }
        return "Version \(app) · input method \(ime.version) (\(ime.build))"
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Backup.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let passphrase = PassphrasePrompt.ask(title: "Restore Backup",
                                                    message: "The passphrase this backup was made with.",
                                                    confirm: false) else { return }
        guard let transfer = Backup.open(data, passphrase: passphrase) else {
            model.failed = true
            model.message = "Wrong passphrase, or not an OctoDot backup."
            return
        }
        Task {
            let (ok, text) = await InstallerClient.shared.importUserData(transfer)
            model.failed = !ok
            model.message = text
        }
    }
}

private struct UpdateRow: View {
    @Bindable var updater: Updater
    var body: some View {
        HStack {
            switch updater.phase {
            case .idle: Text("Software Update")
            case .checking: ProgressView().controlSize(.small); Text("Checking…")
            case .upToDate: Label("OctoDot is up to date.", systemImage: "checkmark.circle")
            case .available(let manifest):
                VStack(alignment: .leading) {
                    Text("OctoDot \(manifest.version) is available.").font(.headline)
                    if !manifest.notes.isEmpty { Text(manifest.notes).font(.callout).foregroundStyle(.secondary) }
                }
            case .downloading: ProgressView().controlSize(.small); Text("Downloading…")
            case .installing: ProgressView().controlSize(.small); Text("Installing…")
            case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer()
            if case .available = updater.phase {
                Button("Install and Relaunch") { Task { await updater.install() } }.buttonStyle(.borderedProminent)
            } else {
                Button("Check for Updates…") { Task { await updater.check() } }
                    .disabled(updater.phase == .checking || updater.phase == .downloading || updater.phase == .installing)
            }
        }
    }
}

/// Uninstalling (section 6 of the plan): keep the data, back it up first, or
/// delete it.
private struct UninstallSheet: View {
    let model: SetupModel
    @Environment(\.dismiss) private var dismiss
    @State private var choice = Choice.keep
    @State private var working = false
    @State private var message: String?

    enum Choice: Hashable { case keep, backup, wipe }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Uninstall OctoDot").font(.title2.weight(.semibold))
            Text("The input method is removed from your input sources and from ~/Library/Input Methods, and this app moves to the Trash.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Your learned words and custom phrases", selection: $choice) {
                Text("Keep them on this Mac").tag(Choice.keep)
                Text("Save an encrypted backup, then delete them").tag(Choice.backup)
                Text("Delete them").tag(Choice.wipe)
            }
            .pickerStyle(.radioGroup)
            if let message { Text(message).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) { Task { await uninstall() } }
                    .keyboardShortcut(.defaultAction).disabled(working)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func uninstall() async {
        working = true
        defer { working = false }
        if choice == .backup {
            guard let transfer = await InstallerClient.shared.exportUserData() else {
                message = "Your data could not be read for the backup; nothing was removed."
                return
            }
            guard let passphrase = PassphrasePrompt.ask(title: "Backup Passphrase",
                                                        message: "The backup is sealed with this passphrase; you need it to restore.",
                                                        confirm: true),
                  let sealed = try? Backup.seal(transfer, passphrase: passphrase) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "OctoDot.\(Backup.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url, (try? sealed.write(to: url, options: .atomic)) != nil else {
                message = "The backup was not saved; nothing was removed."
                return
            }
        }
        let (ok, text) = await InstallerClient.shared.uninstall(wipe: choice != .keep)
        guard ok else {
            message = text
            return
        }
        GrammarStore.removeAll()                    // not the user's data: 400 MB a reinstall brings back
        model.message = text
        NSApp.terminate(nil)
    }
}

/// A passphrase, asked in an alert (twice, when it is being chosen).
@MainActor
enum PassphrasePrompt {
    static func ask(title: String, message: String, confirm: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let first = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 30 : 0, width: 260, height: 24))
        first.placeholderString = "Passphrase"
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        second.placeholderString = "Again"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: confirm ? 54 : 24))
        box.addSubview(first)
        if confirm { box.addSubview(second) }
        alert.accessoryView = box
        alert.window.initialFirstResponder = first
        guard alert.runModal() == .alertFirstButtonReturn, first.stringValue.count >= 8,
              !confirm || first.stringValue == second.stringValue else { return nil }
        return first.stringValue
    }
}
