import AppKit
import Observation
import SwiftUI

/// The settings window, opened from the input menu's one item, built as
/// System Settings is: a sidebar of panes and a grouped form for each, so
/// macOS 26 draws it in its own design (the sidebar as floating Liquid
/// Glass, content scrolling under the toolbar's glass edge). Made once and
/// reused while the core runs; when it stops, the window is closed and let
/// go, with its views (the core's library stays loaded after a newer one
/// replaces it, and so would a window held here; a newer core makes its own).
@MainActor
enum SettingsWindow {
    private static var window: NSWindow?
    private static let model = SettingsModel()
    private static var observer: (any NSObjectProtocol)?

    static func show() {
        let window = self.window ?? make()
        self.window = window
        model.refresh()
        // An input method is never the active app; the window comes forward
        // regardless, so it does not open behind the app being typed in.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    /// The core stops: the window is closed and let go, views and all.
    static func close() {
        ColorPanel.shared.close()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        model.onTitle = nil
        guard let window else { return }
        window.orderOut(nil)
        window.close()
        window.contentViewController = nil
        window.toolbar = nil
        self.window = nil
    }

    /// For checking that `close` frees the window: makes it, shows it out of
    /// sight, and returns it and its view controllers.
    static func makeOffscreen() -> [AnyObject] {
        let window = make()
        self.window = window
        model.refresh()
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.orderFrontRegardless()
        var objects: [AnyObject] = [window]
        if let split = window.contentViewController as? NSSplitViewController {
            objects.append(split)
            objects += split.splitViewItems.map(\.viewController)
        }
        return objects
    }

    private static func make() -> NSWindow {
        // AppKit's split view, whose sidebar item macOS 26 floats as Liquid
        // Glass (a SwiftUI split view hosted in AppKit stays flat), with the
        // SwiftUI list and forms inside it.
        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: Sidebar(model: model)))
        sidebar.canCollapse = false
        sidebar.minimumThickness = 190
        sidebar.maximumThickness = 260
        split.addSplitViewItem(sidebar)
        let detail = NSSplitViewItem(viewController: NSHostingController(rootView: Detail(model: model)))
        detail.minimumThickness = 440
        split.addSplitViewItem(detail)

        let window = NSWindow(contentViewController: split)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        // A unified toolbar, even with nothing in it: the sidebar runs up under it.
        window.toolbar = NSToolbar(identifier: "OctoDotSettings")
        window.toolbarStyle = .unified
        model.onTitle = { [weak window] title in window?.title = title }
        model.syncTitle()
        window.contentMinSize = NSSize(width: 640, height: 440)
        // Fit the full Input pane on a tall display while keeping the window on screen.
        let preferredHeight: CGFloat = 780
        let availableHeight = (window.screen ?? NSScreen.main).map {
            window.contentRect(forFrameRect: $0.visibleFrame).height
        } ?? preferredHeight
        window.setContentSize(NSSize(width: 720, height: min(preferredHeight, availableHeight)))
        window.isReleasedWhenClosed = false
        window.center()
        // Back from the text editor (custom phrases), or another app: show what changed.
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                                          object: window, queue: .main) { _ in
            MainActor.assumeIsolated { model.refresh() }
        }
        return window
    }

    /// For looking at the design (OctoDot --settings-preview): shows the
    /// window on screen, as offscreen drawing has no Liquid Glass, and each
    /// pane in turn, calling `ready` with the window's number once a pane is
    /// in place, for a screen capture of that window.
    static func preview(dwell: TimeInterval, ready: (Pane, Int) -> Void) {
        let window = make()
        model.refresh()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for pane in Pane.allCases {
            model.pane = pane
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.9))
            ready(pane, window.windowNumber)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: dwell))
        }
        window.close()
    }

    /// The companion's file panel chose an app, or was cancelled. A choice is
    /// added (or opened, if it was already there) and the window comes forward.
    static func acceptPickedApp() {
        if let choice = AppPick.take() {
            AppRules.upsert(id: choice.id, name: choice.name)
            model.pane = .apps
            model.openApp = choice.id
        }
        show()
    }
}

/// The window's panes, as System Settings shows its own: a colored tile, a
/// title, and what the pane is for.
enum Pane: String, CaseIterable, Identifiable, Sendable {
    case input, appearance, lexicon, apps, privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .input: "输入"
        case .appearance: "外观"
        case .lexicon: "词库"
        case .apps: "应用"
        case .privacy: "隐私"
        }
    }

    var symbol: String {
        switch self {
        case .input: "keyboard.fill"
        case .appearance: "paintpalette.fill"
        case .lexicon: "books.vertical.fill"
        case .apps: "square.grid.2x2.fill"
        case .privacy: "hand.raised.fill"
        }
    }

    var tint: Color {
        switch self {
        case .input: .gray
        case .appearance: .purple
        case .lexicon: .orange
        case .apps: Color(red: 0.10, green: 0.46, blue: 0.44)
        case .privacy: .blue
        }
    }
}

private struct Sidebar: View {
    @Bindable var model: SettingsModel

    var body: some View {
        List(Pane.allCases, selection: $model.pane) { pane in
            Label {
                Text(pane.title)
            } icon: {
                PaneIcon(pane: pane, size: 22)
            }
            .tag(pane)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)       // the sidebar's glass shows through
    }
}

private struct Detail: View {
    let model: SettingsModel

    var body: some View {
        switch model.pane ?? .input {
        case .input: InputPane(model: model)
        case .appearance: AppearancePane(model: model)
        case .lexicon: LexiconPane(model: model)
        case .apps:
            if let id = model.openApp { AppPane(model: model, id: id) }
            else { AppsPane(model: model) }
        case .privacy: PrivacyPane(model: model)
        }
    }
}

/// A pane's tile: its symbol in white on a rounded square of its color.
private struct PaneIcon: View {
    let pane: Pane
    let size: CGFloat

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(pane.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// The top of a pane, as in System Settings: its tile and title.
private struct PaneHeader: View {
    let pane: Pane

    var body: some View {
        Section {
            VStack(spacing: 8) {
                PaneIcon(pane: pane, size: 54)
                Text(pane.title).font(.title2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .padding(.horizontal, 24)
        }
    }
}

/// What the window shows and changes: read from the engine and the stored
/// preferences whenever the window opens or comes forward, and changed
/// through the same calls the input menu used to make.
@MainActor
@Observable
final class SettingsModel {
    var ready = false
    var schemes: [Engine.Scheme] = []
    var scheme = ""
    var auxSchemes: [Engine.Scheme] = []
    var auxScheme = ""
    var fullCharset = false
    var fuzzy: [Engine.FuzzyGroup] = []
    var english = true
    var sets: [Engine.LexiconSet] = []
    var incognito = false
    var phrases = ""
    var health: String?
    var forgot: String?
    var translationModifier = TranslationModifier.current
    var style = CandidateStyle.current
    var apps: [AppRules.Entry] = []
    /// The bundle id of the app whose page is open, or nil for the list.
    var openApp: String? {
        didSet { if openApp != oldValue { syncTitle() } }
    }
    var pane: Pane? = .input {
        didSet {
            if pane != .apps { openApp = nil }
            syncTitle()
        }
    }
    /// The window title: the pane's, or the open app's name.
    @ObservationIgnored var onTitle: ((String) -> Void)?

    func syncTitle() { onTitle?(chromeTitle) }

    private var chromeTitle: String {
        if pane == .apps, let openApp, let name = AppRules.entries.first(where: { $0.id == openApp })?.name {
            return name
        }
        return (pane ?? .input).title
    }

    func refresh() {
        AppRules.reload()
        apps = AppRules.entries
        if let openApp, !apps.contains(where: { $0.id == openApp }) { self.openApp = nil }
        syncTitle()
        translationModifier = TranslationModifier.current
        style = CandidateStyle.current
        incognito = Learning.incognito
        health = Health.menuLine
        ready = Engine.shared.isReady
        guard ready else { return }             // the engine's lists exist only while it runs
        schemes = Engine.shared.schemes()
        scheme = Learning.scheme
        auxSchemes = Engine.shared.auxSchemes()
        auxScheme = Learning.auxScheme
        fullCharset = Learning.fullCharset
        fuzzy = Engine.shared.fuzzyGroups()
        english = Learning.englishOn
        sets = Engine.shared.lexiconSets()
        phrases = Phrases.statusLine
    }

    func useScheme(_ id: String) { Learning.useScheme(id); refresh() }
    func useAuxScheme(_ id: String) { Learning.useAuxScheme(id); refresh() }
    func useFullCharset(_ on: Bool) { Learning.useFullCharset(on); refresh() }
    func useFuzzy(_ id: String, on: Bool) { Learning.useFuzzy(id, on: on); refresh() }
    func useEnglish(_ on: Bool) { Learning.useEnglish(on); refresh() }
    func useSet(_ id: String, on: Bool) { Learning.useSet(id, on: on); refresh() }
    func setIncognito(_ on: Bool) { Learning.incognito = on; refresh() }
    func editPhrases() { Phrases.edit() }

    func setTranslationModifier(_ modifier: TranslationModifier) {
        guard modifier != TranslationModifier.current else { return }
        TranslationModifier.select(modifier)
        CandidatePanel.translationModifierChanged()
        TranslationChords.reconfigure()
        translationModifier = TranslationModifier.current
    }

    func setFontSize(_ size: Double) { change { $0.fontSize = CGFloat(size) } }
    func setAccent(_ accent: String) { change { $0.accent = accent } }
    func setInset(_ inset: Double) { change { $0.inset = CGFloat(inset) } }
    func resetAppearance() { change { $0 = CandidateStyle() } }

    private func change(_ edit: (inout CandidateStyle) -> Void) {
        var next = style
        edit(&next)
        guard next != style else { return }
        next.use()
        style = next
    }

    func addApp() { Companion.open("pick-app") }

    func showApp(_ id: String) { openApp = id }

    func showAppList() { openApp = nil }

    func setAppHalfwidth(_ on: Bool, id: String) {
        AppRules.setHalfwidth(on, for: id)
        refresh()
    }

    func setAppNoLearn(_ on: Bool, id: String) {
        AppRules.setNoLearn(on, for: id)
        refresh()
    }

    func removeApp(_ id: String) {
        AppRules.remove(id)
        if openApp == id { openApp = nil }
        refresh()
    }

    func forget(_ scope: Engine.ForgetScope) {
        Learning.forget(scope)
        forgot = switch scope {
        case .lastFifteenMinutes: "已忘记最近 15 分钟学到的内容。"
        case .today: "已忘记今天学到的内容。"
        case .everything: "已忘记所有学到的内容。"
        }
    }
}

private struct InputPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .input)
            Section {
                Picker("输入方案", selection: Binding(get: { model.scheme }, set: { model.useScheme($0) })) {
                    ForEach(model.schemes, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("形码", selection: Binding(get: { model.auxScheme },
                                                 set: { model.useAuxScheme($0) })) {
                    Text("无").tag("none")
                    ForEach(model.auxSchemes, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("全部汉字", isOn: Binding(get: { model.fullCharset },
                                                              set: { model.useFullCharset($0) }))
            }
            if !model.fuzzy.isEmpty {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(model.fuzzy, id: \.id) { group in
                            Toggle(group.title, isOn: Binding(get: { group.on },
                                                              set: { model.useFuzzy(group.id, on: $0) }))
                        }
                    }
                } header: {
                    Text("模糊音")
                }
            }
            if #available(macOS 26.0, *) {
                Section {
                    Picker("翻译按键", selection: Binding(get: { model.translationModifier },
                                                        set: { model.setTranslationModifier($0) })) {
                        ForEach(TranslationModifier.allCases) { modifier in
                            Text(modifier.label).tag(modifier)
                        }
                    }
                    Button("打开系统设置…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } header: {
                    Text("翻译")
                } footer: {
                    Note("翻译在本机进行，优先使用内置词汇表。词汇表未收录的内容使用系统翻译；如需下载中英文语言，请在系统设置的“通用 → 语言与地区 → 翻译语言”中安装“简体中文”和“英文（美国）”。")
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!model.ready)
        .overlay { if !model.ready { NotReady() } }
    }
}

private struct AppearancePane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .appearance)
            Section {
                LabeledContent("字号") {
                    Measure(value: Binding(get: { Double(model.style.fontSize) }, set: { model.setFontSize($0) }),
                            range: CandidateStyle.fontSizes)
                }
                LabeledContent("强调色") {
                    AccentPicker(model: model)
                }
                LabeledContent("高亮边距") {
                    Measure(value: Binding(get: { Double(model.style.inset) }, set: { model.setInset($0) }),
                            range: CandidateStyle.insets)
                }
            } footer: {
                HStack {
                    Spacer()
                    Button("恢复默认") { model.resetAppearance() }
                        .disabled(model.style == CandidateStyle())
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// A slider in whole points, with its value beside it.
private struct Measure: View {
    @Binding var value: Double
    let range: ClosedRange<CGFloat>

    var body: some View {
        HStack(spacing: 10) {
            Slider(value: $value, in: Double(range.lowerBound)...Double(range.upperBound), step: 1)
                .labelsHidden()
                .frame(width: 170)
            Text("\(Int(value)) pt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

/// The accent colors as swatches, like System Settings' own, with the
/// system's accent first and a color of one's own last.
private struct AccentPicker: View {
    let model: SettingsModel

    var body: some View {
        HStack(spacing: 4) {
            Swatch(fill: AnyShapeStyle(AngularGradient(colors: [.blue, .purple, .pink, .red, .orange, .yellow, .green, .blue],
                                                       center: .center)),
                   selected: model.style.accent == "system", help: "系统强调色") {
                model.setAccent("system")
            }
            ForEach(CandidateStyle.presets, id: \.id) { preset in
                Swatch(fill: AnyShapeStyle(Color(nsColor: CandidateStyle(accent: preset.id).accentColor)),
                       selected: model.style.accent == preset.id, help: preset.name) {
                    model.setAccent(preset.id)
                }
            }
            let own = CandidateStyle.color(hex: model.style.accent)
            Button {
                ColorPanel.shared.open(with: model.style.accentColor) { color in
                    if let hex = CandidateStyle.hex(color) { model.setAccent(hex) }
                }
            } label: {
                ZStack {
                    if let own {
                        Circle().fill(Color(nsColor: own))
                    } else {
                        Circle().strokeBorder(.secondary.opacity(0.6), lineWidth: 1)
                        Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                .padding(3)
                .overlay(Circle().strokeBorder(own != nil ? Color.primary.opacity(0.55) : .clear, lineWidth: 2))
            }
            .buttonStyle(.plain)
            .help("自定义颜色")
            .accessibilityLabel("自定义颜色")
        }
    }
}

/// The system's color panel, for a color of one's own: its changes go to
/// whoever opened it last.
@MainActor
final class ColorPanel: NSObject {
    static let shared = ColorPanel()
    private var onChange: ((NSColor) -> Void)?

    func open(with color: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = nil                     // setting the color below must not count as a choice
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.color = color
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        self.onChange = onChange
        panel.orderFront(nil)
    }

    /// The core stops: the panel would otherwise keep talking to it.
    func close() {
        onChange = nil
        if NSColorPanel.sharedColorPanelExists {
            NSColorPanel.shared.setTarget(nil)
            NSColorPanel.shared.close()
        }
    }

    @objc private func changed(_ panel: NSColorPanel) { onChange?(panel.color) }
}

private struct Swatch: View {
    let fill: AnyShapeStyle
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(fill)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.55) : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppsPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .apps)
            if !model.apps.isEmpty {
                Section {
                    ForEach(model.apps) { app in
                        Button { model.showApp(app.id) } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: AppRules.icon(for: app.id, side: 28))
                                    .frame(width: 28, height: 28)
                                Text(app.name)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 12)
                                Text(app.statusTitle)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .layoutPriority(1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(app.name)，\(app.statusTitle)")
                    }
                }
            }
            Section {
                Button("添加应用…") { model.addApp() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppPane: View {
    @Bindable var model: SettingsModel
    let id: String

    private var entry: AppRules.Entry? { model.apps.first { $0.id == id } }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    HStack {
                        Button { model.showAppList() } label: {
                            Label(Pane.apps.title, systemImage: "chevron.backward")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                    Image(nsImage: AppRules.icon(for: id, side: 54))
                        .frame(width: 54, height: 54)
                    Text(entry?.name ?? id)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section {
                Picker("标点样式", selection: Binding(get: { entry?.halfwidthPunctuation ?? false },
                                                     set: { model.setAppHalfwidth($0, id: id) })) {
                    Text(AppRules.Entry.followDefault).tag(false)
                    Text(AppRules.Entry.halfwidth).tag(true)
                }
            }
            Section {
                Toggle("不学习用户输入行为", isOn: Binding(get: { entry?.noLearn ?? false },
                                                   set: { model.setAppNoLearn($0, id: id) }))
            } footer: {
                Note("开启后，OctoDot 不会从你在此应用中的输入和选词学习。已学词条仍可使用。")
            }
            Section {
                Button("移除", role: .destructive) { model.removeApp(id) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LexiconPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .lexicon)
            Section("万象词库") {
                ForEach(model.sets, id: \.id) { set in
                    Toggle(set.name, isOn: Binding(get: { set.mounted }, set: { model.useSet(set.id, on: $0) }))
                }
                Toggle("英文单词", isOn: Binding(get: { model.english }, set: { model.useEnglish($0) }))
            }
            Section {
                LabeledContent("自定义短语") {
                    Button("编辑…") { model.editPhrases() }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(!model.ready)
        .overlay { if !model.ready { NotReady() } }
    }
}

private struct PrivacyPane: View {
    let model: SettingsModel
    @State private var confirmingEverything = false

    var body: some View {
        Form {
            PaneHeader(pane: .privacy)
            Section {
                Toggle("无痕模式", isOn: Binding(get: { model.incognito }, set: { model.setIncognito($0) }))
            } footer: {
                Note("无痕模式下不学习用户的输入习惯")
            }
            Section {
                LabeledContent("最近 15 分钟") {
                    Button("忘记") { model.forget(.lastFifteenMinutes) }
                }
                LabeledContent("今天") {
                    Button("忘记") { model.forget(.today) }
                }
                LabeledContent("全部") {
                    Button("忘记…", role: .destructive) { confirmingEverything = true }
                }
            } header: {
                Text("忘记已学内容")
            } footer: {
                if let forgot = model.forgot {
                    Note(forgot)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("忘记八千点学到的所有内容？", isPresented: $confirmingEverything) {
            Button("全部忘记", role: .destructive) { model.forget(.everything) }
        } message: {
            Text("从你的输入中学到的词和短语会被删除，无法撤销。")
        }
    }
}

/// A short line under a section, aligned with its rows, as in System Settings.
private struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotReady: View {
    var body: some View {
        Text("词库未能加载，输入将原样通过。")
            .foregroundStyle(.secondary)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
