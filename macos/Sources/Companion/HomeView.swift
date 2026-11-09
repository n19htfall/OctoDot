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
                Label(model.enabled ? "输入法已安装，并在输入源中。"
                                    : "输入法已安装，但还没有加入输入源。",
                      systemImage: model.enabled ? "checkmark.seal.fill" : "exclamationmark.circle")
                    .foregroundStyle(model.enabled ? Color.green : Color.orange)
                HStack {
                    Button("打开设置…") { IMELink.showSettings() }.buttonStyle(.borderedProminent)
                    if !model.enabled { Button("去设置…") { model.screen = .wizard; model.step = .install } }
                }
            }
            Card {
                UpdateRow(updater: updater)
                Toggle("自动检查更新", isOn: $updater.automatic)
                Text("只有这个应用会通过 HTTPS 检查由 OctoDot 密钥签名的发布。输入法本身从不使用网络。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let share = model.grammarProgress { GrammarDownload(share: share) }
            if let message = model.message {
                Label(message, systemImage: model.failed ? "exclamationmark.triangle.fill" : "info.circle")
                    .foregroundStyle(model.failed ? .orange : .secondary).font(.callout).textSelection(.enabled)
            }
            Spacer()
            HStack {
                Button("恢复备份…") { restore() }
                Spacer()
                Button("卸载 OctoDot…", role: .destructive) { uninstalling = true }
            }
        }
        .padding(28)
        .frame(width: 620, height: 500)
        .sheet(isPresented: $uninstalling) { UninstallSheet(model: model) }
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let app = "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
        guard let ime = model.facts?.installed else { return "版本 \(app)" }
        return "版本 \(app) · 输入法 \(ime.version)（\(ime.build)）"
    }

    private func restore() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: Backup.fileExtension) ?? .data]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url),
              let passphrase = PassphrasePrompt.ask(title: "恢复备份",
                                                    message: "请输入制作这份备份时用的口令。",
                                                    confirm: false) else { return }
        guard let transfer = Backup.open(data, passphrase: passphrase) else {
            model.failed = true
            model.message = "口令不对，或这不是 OctoDot 的备份。"
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
            case .idle: Text("软件更新")
            case .checking: ProgressView().controlSize(.small); Text("正在检查…")
            case .upToDate: Label("OctoDot 已是最新。", systemImage: "checkmark.circle")
            case .available(let manifest):
                VStack(alignment: .leading) {
                    Text("OctoDot \(manifest.version) 可供更新。").font(.headline)
                    if !manifest.notes.isEmpty { Text(manifest.notes).font(.callout).foregroundStyle(.secondary) }
                }
            case .downloading: ProgressView().controlSize(.small); Text("正在下载…")
            case .installing: ProgressView().controlSize(.small); Text("正在安装…")
            case .failed(let why): Label(why, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer()
            if case .available = updater.phase {
                Button("安装并重新打开") { Task { await updater.install() } }.buttonStyle(.borderedProminent)
            } else {
                Button("检查更新…") { Task { await updater.check(interactive: true) } }
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
            Text("卸载 OctoDot").font(.title2.weight(.semibold))
            Text("输入法会从输入源和 ~/Library/Input Methods 中移除，这个应用会移到废纸篓。")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("已学词条和自定义短语", selection: $choice) {
                Text("保留在这台 Mac 上").tag(Choice.keep)
                Text("先保存加密备份，再删除").tag(Choice.backup)
                Text("删除").tag(Choice.wipe)
            }
            .pickerStyle(.radioGroup)
            if let message { Text(message).foregroundStyle(.orange).font(.callout) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("卸载", role: .destructive) { Task { await uninstall() } }
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
                message = "无法读取数据来制作备份，什么都没有移除。"
                return
            }
            guard let passphrase = PassphrasePrompt.ask(title: "备份口令",
                                                        message: "备份用这个口令封存，恢复时需要它。",
                                                        confirm: true),
                  let sealed = try? Backup.seal(transfer, passphrase: passphrase) else { return }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "OctoDot.\(Backup.fileExtension)"
            guard panel.runModal() == .OK, let url = panel.url, (try? sealed.write(to: url, options: .atomic)) != nil else {
                message = "备份没有保存，什么都没有移除。"
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
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        let first = NSSecureTextField(frame: NSRect(x: 0, y: confirm ? 30 : 0, width: 260, height: 24))
        first.placeholderString = "口令"
        let second = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        second.placeholderString = "再输入一次"
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
