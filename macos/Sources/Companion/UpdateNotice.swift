import AppKit
import SwiftUI

/// The window a manual "Check for Updates…" opens. It stays up for every
/// outcome: already current, a newer release, or a failed check. A background
/// check never opens it. The body is Liquid Glass, as the candidate window is.
@MainActor
final class UpdateNotice {
    static let shared = UpdateNotice()

    private var panel: UpdatePanel?
    private var controller: NoticeController?
    private var applied = CGSize.zero

    var isVisible: Bool { panel?.isVisible ?? false }

    func present(_ updater: Updater) {
        let fresh = panel?.isVisible != true
        ensure(updater)
        guard let panel else { return }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if fresh { recenter() }
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func ensure(_ updater: Updater) {
        guard panel == nil else { return }
        let controller = NoticeController(rootView: UpdateNoticeView(updater: updater, onClose: { [weak self] in
            self?.close()
        }))
        controller.sizingOptions = .preferredContentSize
        controller.safeAreaRegions = []
        controller.onSize = { [weak self] size in self?.apply(size) }
        let panel = UpdatePanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 280),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "软件更新"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .modalPanel
        panel.isMovableByWindowBackground = true
        panel.animationBehavior = .alertPanel
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = Self.glass(around: controller.view)
        panel.hasShadow = if #available(macOS 26.0, *) { false } else { true }
        self.controller = controller
        self.panel = panel
    }

    /// Liquid Glass on macOS 26; a window blur before that. The glass draws
    /// its own edge, so the window itself stays clear.
    private static func glass(around content: NSView) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 18
            glass.contentView = content
            return glass
        }
        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.masksToBounds = true
        content.frame = NSRect(x: 0, y: 0, width: 360, height: 280)
        content.autoresizingMask = [.width, .height]
        blur.addSubview(content)
        return blur
    }

    private func apply(_ size: CGSize) {
        guard let panel, size.width > 80, size.height > 80, size.height < 720 else { return }
        if abs(applied.width - size.width) < 0.5, abs(applied.height - size.height) < 0.5 { return }
        let previous = applied
        applied = size
        var frame = panel.frame
        frame.size = size
        if previous == .zero || !panel.isVisible {
            panel.setFrame(frame, display: true)
            recenter()
        } else {
            frame.origin.x -= (size.width - previous.width) / 2
            frame.origin.y -= (size.height - previous.height) / 2
            panel.setFrame(frame, display: true)
        }
    }

    private func recenter() {
        guard let panel, applied.width > 1 else { return }
        let area = panel.screen?.visibleFrame ?? NSApp.keyWindow?.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame ?? panel.frame
        var frame = panel.frame
        frame.size = applied
        frame.origin.x = area.midX - applied.width / 2
        frame.origin.y = area.midY - applied.height / 2
        panel.setFrame(frame, display: true)
    }
}

private final class UpdatePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class NoticeController: NSHostingController<UpdateNoticeView> {
    var onSize: ((NSSize) -> Void)?
    private var reported = CGSize.zero

    override func viewDidLayout() {
        super.viewDidLayout()
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
        view.layer?.isOpaque = false
        let size = preferredContentSize
        guard size.width > 1, size.height > 1 else { return }
        guard abs(reported.width - size.width) > 0.5 || abs(reported.height - size.height) > 0.5 else { return }
        reported = size
        // After this layout pass: resizing the window from inside it recurses.
        Task { @MainActor in onSize?(size) }
    }
}

private struct UpdateNoticeView: View {
    @Bindable var updater: Updater
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .padding(.bottom, 18)
            Text(headline)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if case .downloading = updater.phase {
                ProgressView(value: downloadFraction)
                    .padding(.top, 16)
                Text(downloadStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            if let notes {
                Text(notes)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            controls
                .padding(.top, 20)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 22)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand(perform: onClose)
    }

    private var headline: String {
        switch updater.phase {
        case .idle, .checking: "正在检查更新…"
        case .upToDate: "你正在使用的是 OctoDot 的最新版本！"
        case .available: "OctoDot 有新版本可供更新"
        case .downloading: "正在下载更新…"
        case .verifying: "正在校验更新…"
        case .installing: "正在安装更新…"
        case .failed(let why): why
        }
    }

    /// The release under the headline. A failure keeps the version that was checked.
    private var detail: String? {
        switch updater.phase {
        case .available(let manifest): manifest.version
        case .downloading, .verifying, .installing: nil
        case .failed: runningVersion
        default: runningVersion
        }
    }

    private var notes: String? {
        guard case .available(let manifest) = updater.phase, !manifest.notes.isEmpty else { return nil }
        return manifest.notes
    }

    private var runningVersion: String? {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return version.isEmpty ? nil : version
    }

    private var downloadFraction: Double {
        min(Double(updater.downloadedBytes) / Double(max(updater.downloadSize, 1)), 1)
    }

    /// Percent, bytes received against the manifest's size, and the average rate.
    private var downloadStatus: String {
        let done = ByteCountFormatter.string(fromByteCount: updater.downloadedBytes, countStyle: .file)
        let size = ByteCountFormatter.string(fromByteCount: updater.downloadSize, countStyle: .file)
        var line = "\(Int(downloadFraction * 100))% · \(done) / \(size)"
        if updater.bytesPerSecond > 0 {
            line += " · \(ByteCountFormatter.string(fromByteCount: updater.bytesPerSecond, countStyle: .file))/s"
        }
        return line
    }

    @ViewBuilder private var controls: some View {
        switch updater.phase {
        case .downloading:
            Button("关闭", action: onClose)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        case .checking, .verifying, .installing, .idle:
            ProgressView()
                .controlSize(.small)
                .padding(.bottom, 10)
            Button("关闭", action: onClose)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        case .available:
            prominent("安装并重新打开") { Task { await updater.install() } }
                .keyboardShortcut(.defaultAction)
                .padding(.bottom, 8)
            Button("稍后", action: onClose)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
        case .upToDate, .failed:
            prominent("确定", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func prominent(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
    }
}
