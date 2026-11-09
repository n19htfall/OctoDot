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
        case .location: "Applications"
        case .install: "Input Method"
        case .privacy: "Privacy"
        case .tryIt: "Try It"
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
            Heading(title: "Move OctoDot to Applications",
                    detail: "OctoDot is running from its disk image. It needs to be in your Applications folder to install its input method and keep itself up to date.")
            Button {
                Task { await model.moveToApplications() }
            } label: {
                Label("Move to Applications and Reopen", systemImage: "folder.badge.plus")
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
            Heading(title: "Set Up the Input Method",
                    detail: "OctoDot installs its input method for you alone (in ~/Library/Input Methods, no password needed) and adds it to your input sources.")
            if model.enabled {
                Label("OctoDot is among your input sources.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Button("Continue") { model.next() }.buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Button {
                    Task { await model.install() }
                } label: {
                    if model.busy { ProgressView().controlSize(.small) } else { Label("Set Up OctoDot Input Method", systemImage: "keyboard") }
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
            }
            if model.showSettingsHelp && !model.enabled {
                Card {
                    Text("Turn OctoDot on in System Settings").font(.headline)
                    Text("Keyboard → Text Input → Input Sources → Edit…, then + and Chinese, Simplified → OctoDot. This step goes on by itself the moment it is on.")
                        .foregroundStyle(.secondary)
                    Button("Open Keyboard Settings…") { model.openKeyboardSettings() }
                }
            }
        }
    }
}

private struct PrivacyStep: View {
    let model: SetupModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading(title: "Private by Design",
                    detail: "OctoDot uses macOS's own input method framework. Its input method never asks for:")
            Card {
                HStack(spacing: 18) {
                    ForEach(["Accessibility", "Input Monitoring", "Clipboard", "Network"], id: \.self) { item in
                        Label(item, systemImage: "nosign").font(.callout)
                    }
                }
                Text("What you type, and what OctoDot learns from it, stays on this Mac, sealed in the input method's sandbox.")
                    .foregroundStyle(.secondary).font(.callout)
            }
            if let preflight = model.preflight {
                Card {
                    Check(ok: preflight.sandboxed && preflight.container, text: "The input method's private storage works, inside its sandbox")
                    Check(ok: preflight.appGroup, text: "Its shared folder with this app is there")
                    Check(ok: preflight.keychain, text: "Its key for your learned words is in your Keychain")
                    Check(ok: preflight.images, text: "Its dictionaries load")
                }
                Button("Continue") { model.next() }.buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(!preflight.ok)
            } else {
                Button {
                    Task { await model.runPreflight() }
                } label: {
                    if model.busy { ProgressView().controlSize(.small) } else { Label("Check", systemImage: "checklist") }
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
            Heading(title: "Try It",
                    detail: "Click the field: OctoDot becomes the input source. Type nihao (or wussqigr in 小鹤双拼), pick with Space or a number.")
            TextField("Type here…", text: $text, axis: .vertical)
                .font(.title3)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onChange(of: focused) { _, now in if now { model.selectIME() } }
            Card {
                Picker("Scheme", selection: Binding(get: { model.scheme }, set: { model.useScheme($0) })) {
                    Text("全拼 Full Pinyin").tag("fullpinyin")
                    Text("小鹤双拼 Xiaohe Shuangpin").tag("flypy")
                }
                .pickerStyle(.segmented)
                Toggle("全部汉字 All characters (not only everyday ones)",
                       isOn: Binding(get: { model.fullCharset }, set: { model.useFullCharset($0) }))
            }
            HStack {
                Spacer()
                Button("Done") { model.finish() }.buttonStyle(.borderedProminent).controlSize(.large)
            }
        }
    }
}
