import SwiftUI

/// The first-run wizard (docs/distribution-and-onboarding.md, section 3): the
/// steps this install needs, one at a time, each finishing itself where it
/// can (the input source turning on moves step B along).
struct OnboardingView: View {
    @Bindable var model: SetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepBar(steps: model.steps, current: model.step)
                .padding(.horizontal, 28)
                .padding(.top, 24)
            Group {
                switch model.step {
                case .location: LocationStep(model: model)
                case .install: InstallStep(model: model)
                case .privacy: PrivacyStep(model: model)
                case .tryIt: TryStep(model: model)
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let message = model.message {
                Label(message, systemImage: model.failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(model.failed ? .orange : .secondary)
                    .font(.callout)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 20)
                    .textSelection(.enabled)
            }
        }
        .frame(width: 620, height: 500)
        .onDisappear { model.stopOnboarding() }
    }
}

/// Where the user is in the wizard.
private struct StepBar: View {
    let steps: [SetupModel.Step]
    let current: SetupModel.Step

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element) { index, step in
                HStack(spacing: 6) {
                    Image(systemName: step < current ? "checkmark.circle.fill" : (step == current ? "\(index + 1).circle.fill" : "\(index + 1).circle"))
                        .foregroundStyle(step <= current ? Color.accentColor : .secondary)
                    Text(title(step)).font(.callout.weight(step == current ? .semibold : .regular))
                        .foregroundStyle(step == current ? .primary : .secondary)
                }
                if index + 1 < steps.count { Rectangle().fill(.separator).frame(height: 1).frame(maxWidth: 24) }
            }
        }
    }

    private func title(_ step: SetupModel.Step) -> String {
        switch step {
        case .location: "应用程序"
        case .install: "输入法"
        case .privacy: "隐私"
        case .tryIt: "试一试"
        }
    }
}

/// A rounded card, in Liquid Glass on macOS 26 and later.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let inner = VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        if #available(macOS 26.0, *) {
            inner.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            inner.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// The grammar model coming down (an update that changes it, or a missing one).
struct GrammarDownload: View {
    var share: Double
    var body: some View {
        ProgressView(value: share) {
            Text("正在下载语法模型…")
        } currentValueLabel: {
            Text("已完成 \(Int(share * 100))%，共 \(GrammarStore.pin.map { $0.size / 1_000_000 } ?? 0) MB")
        }
    }
}

private struct Heading: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.title2.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 14)
    }
}

private struct LocationStep: View {
    let model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading(title: "把 OctoDot 移到“应用程序”",
                    detail: "OctoDot 正在从磁盘映像里运行。要安装输入法并保持更新，需要先把它放到“应用程序”文件夹。")
            Button {
                model.runOnboardingAction { await $0.moveToApplications() }
            } label: {
                Label("移到“应用程序”并重新打开", systemImage: "folder.badge.plus")
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
        }
    }
}

private struct InstallStep: View {
    let model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Heading(title: "设置输入法",
                    detail: "OctoDot 只为当前用户安装输入法（放在 ~/Library/Input Methods，不需要密码），并把它加入输入源。")
            if model.enabled {
                Label("OctoDot 已在输入源中。", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button("继续") { model.next() }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button {
                    model.runOnboardingAction { await $0.install() }
                } label: {
                    if model.busy { ProgressView().controlSize(.small) } else { Label("设置 OctoDot 输入法", systemImage: "keyboard") }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
            }
            if let share = model.grammarProgress { GrammarDownload(share: share) }
            if model.canCancelOnboardingAction {
                Button("停止等待") { model.cancelOnboardingAction() }
            }
            if model.showSettingsHelp && !model.enabled {
                Card {
                    Text("在系统设置中打开 OctoDot").font(.headline)
                    Text("键盘 → 文本输入 → 输入法 → 编辑…，点 +，再选「简体中文」→ OctoDot。一旦打开，这一步会自动继续。")
                        .foregroundStyle(.secondary)
                    Button("打开键盘设置…") { model.openKeyboardSettings() }
                }
            }
        }
    }
}

private struct PrivacyStep: View {
    let model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading(title: "默认保护隐私",
                    detail: "OctoDot 使用 macOS 自带的输入法框架。它的输入法不会请求这些权限：")
            Card {
                HStack(spacing: 18) {
                    ForEach(["辅助功能", "输入监控", "剪贴板", "网络"], id: \.self) { item in
                        Label(item, systemImage: "nosign").font(.callout)
                    }
                }
                Text("你输入的内容，以及 OctoDot 据此学到的词，都留在这台 Mac 上，封在输入法的沙盒里。")
                    .foregroundStyle(.secondary).font(.callout)
            }
            if let preflight = model.preflight {
                Card {
                    Check(ok: preflight.sandboxed && preflight.container, text: "输入法的私有存储可用，且位于沙盒内")
                    Check(ok: preflight.appGroup, text: "与本应用共享的文件夹已就绪")
                    Check(ok: preflight.keychain, text: "已学词条的密钥在「钥匙串」中")
                    Check(ok: preflight.images, text: "词库可以加载")
                }
                Button("继续") { model.next() }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!preflight.ok)
            } else {
                Button {
                    model.runOnboardingAction { await $0.runPreflight() }
                } label: {
                    if model.busy { ProgressView().controlSize(.small) } else { Label("检查", systemImage: "checklist") }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.busy)
            }
        }
    }
}

private struct Check: View {
    let ok: Bool
    let text: String
    var body: some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
            .foregroundStyle(ok ? Color.green : Color.red)
    }
}

private struct TryStep: View {
    @Bindable var model: SetupModel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading(title: "试一试",
                    detail: "选一个输入方案，点一下输入框试打，再用空格或数字选词。")
            TextField("在这里输入…", text: $text, axis: .vertical)
                .font(.title3)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onChange(of: focused) { _, now in if now { model.selectIME() } }
            Card {
                Picker("方案", selection: Binding(get: { model.scheme }, set: { model.useScheme($0) })) {
                    ForEach(model.schemes, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("全部汉字（不只常用字）",
                       isOn: Binding(get: { model.fullCharset }, set: { model.useFullCharset($0) }))
            }
            HStack {
                Spacer()
                Button("完成") { model.finish() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}
