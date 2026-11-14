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
        model.release()
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
        model.onTitle = { [weak window] title in
            guard let window, window.title != title else { return }
            window.title = title
        }
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
            if let entry = model.openEntry { AppPane(model: model, entry: entry) }
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

/// The settings panes bind to properties that apply changes to the live
/// engine or preferences. Opening or refocusing the window rereads the
/// settings and publishes a new snapshot only when something has changed.
@MainActor
@Observable
final class SettingsModel {
    /// The engine's lists and the stored preferences, as last read.
    @MainActor
    struct Values: Equatable {
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
        var translationModifier = TranslationModifier.current
        var style = CandidateStyle.current
        var apps: [AppRules.Entry] = []

        /// Read now. The engine's lists exist only while it runs: until it
        /// does, they stay as `previous` had them.
        static func read(keeping previous: Values) -> Values {
            AppRules.reload()
            var next = previous
            next.apps = AppRules.entries
            next.translationModifier = TranslationModifier.current
            next.style = CandidateStyle.current
            next.incognito = Learning.incognito
            next.ready = Engine.shared.isReady
            guard next.ready else { return next }
            next.schemes = Engine.shared.schemes()
            next.scheme = Learning.scheme
            next.auxSchemes = Engine.shared.auxSchemes()
            next.auxScheme = Learning.auxScheme
            next.fullCharset = Learning.fullCharset
            next.fuzzy = Engine.shared.fuzzyGroups()
            next.english = Learning.englishOn
            next.sets = Engine.shared.lexiconSets()
            return next
        }
    }

    private var values = Values()
    /// What the last "forget" did, shown under the privacy pane's buttons.
    private(set) var forgot: String?
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
    /// The apps' icons, looked up once each (Launch Services is not free,
    /// and a list row asks again every time it is drawn).
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    func refresh() {
        let next = Values.read(keeping: values)
        if next != values { values = next }
        if let openApp, !values.apps.contains(where: { $0.id == openApp }) { self.openApp = nil }
        syncTitle()
    }

    /// The window closes for good: what it looked up goes with it.
    func release() {
        onTitle = nil
        icons.removeAll()
    }

    func syncTitle() { onTitle?(chromeTitle) }

    private var chromeTitle: String {
        if pane == .apps, let entry = openEntry { return entry.name }
        return (pane ?? .input).title
    }

    // MARK: What the panes read

    var ready: Bool { values.ready }
    var schemes: [Engine.Scheme] { values.schemes }
    var auxSchemes: [Engine.Scheme] { values.auxSchemes }
    var fuzzy: [Engine.FuzzyGroup] { values.fuzzy }
    var sets: [Engine.LexiconSet] { values.sets }
    var apps: [AppRules.Entry] { values.apps }
    var style: CandidateStyle { values.style }

    // MARK: Input and lexicon

    var scheme: String {
        get { values.scheme }
        set { Learning.useScheme(newValue); refresh() }
    }

    var auxScheme: String {
        get { values.auxScheme }
        set { Learning.useAuxScheme(newValue); refresh() }
    }

    var fullCharset: Bool {
        get { values.fullCharset }
        set { Learning.useFullCharset(newValue); refresh() }
    }

    /// The fuzzy groups that are on, by id.
    var fuzzyOn: Set<String> {
        get { Set(values.fuzzy.filter(\.on).map(\.id)) }
        set {
            for group in values.fuzzy where newValue.contains(group.id) != group.on {
                Learning.useFuzzy(group.id, on: !group.on)
            }
            refresh()
        }
    }

    var english: Bool {
        get { values.english }
        set { Learning.useEnglish(newValue); refresh() }
    }

    /// The lexicon sets that are mounted, by id.
    var mountedSets: Set<String> {
        get { Set(values.sets.filter(\.mounted).map(\.id)) }
        set {
            for set in values.sets where newValue.contains(set.id) != set.mounted {
                Learning.useSet(set.id, on: !set.mounted)
            }
            refresh()
        }
    }

    var translationModifier: TranslationModifier {
        get { values.translationModifier }
        set {
            guard newValue != TranslationModifier.current else { return }
            TranslationModifier.select(newValue)
            CandidatePanel.translationModifierChanged()
            TranslationChords.reconfigure()
            values.translationModifier = TranslationModifier.current
        }
    }

    func editPhrases() { Phrases.edit() }

    // MARK: Appearance

    var fontSize: Double {
        get { Double(values.style.fontSize) }
        set { changeStyle { $0.fontSize = CGFloat(newValue) } }
    }

    var inset: Double {
        get { Double(values.style.inset) }
        set { changeStyle { $0.inset = CGFloat(newValue) } }
    }

    /// "system", a preset's id, or "#RRGGBB" (CandidateStyle.accent).
    var accent: String {
        get { values.style.accent }
        set { changeStyle { $0.accent = newValue } }
    }

    func resetAppearance() { changeStyle { $0 = CandidateStyle() } }

    private func changeStyle(_ edit: (inout CandidateStyle) -> Void) {
        var next = values.style
        edit(&next)
        guard next != values.style else { return }
        next.use()
        values.style = next
    }

    // MARK: Apps

    func addApp() { Companion.open("pick-app") }

    /// The open app's rules. Setting them stores what changed.
    var openEntry: AppRules.Entry? {
        get { openApp.flatMap { id in values.apps.first { $0.id == id } } }
        set {
            guard let newValue, let old = openEntry, old.id == newValue.id else { return }
            if newValue.halfwidthPunctuation != old.halfwidthPunctuation {
                AppRules.setHalfwidth(newValue.halfwidthPunctuation, for: old.id)
            }
            if newValue.noLearn != old.noLearn { AppRules.setNoLearn(newValue.noLearn, for: old.id) }
            refresh()
        }
    }

    func removeApp(_ id: String) {
        AppRules.remove(id)
        if openApp == id { openApp = nil }
        refresh()
    }

    func icon(for id: String, side: CGFloat) -> NSImage {
        let key = "\(id) \(side)"
        if let known = icons[key] { return known }
        let image = AppRules.icon(for: id, side: side)
        icons[key] = image
        return image
    }

    // MARK: Privacy

    var incognito: Bool {
        get { values.incognito }
        set { Learning.incognito = newValue; refresh() }
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

private extension Set {
    /// A writable membership value for a toggle binding.
    subscript(contains element: Element) -> Bool {
        get { contains(element) }
        set {
            if newValue { insert(element) } else { remove(element) }
        }
    }
}

private struct InputPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .input)
            Section {
                Picker("输入方案", selection: $model.scheme) {
                    ForEach(model.schemes, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("形码", selection: $model.auxScheme) {
                    Text("无").tag("none")
                    ForEach(model.auxSchemes, id: \.id) { Text($0.name).tag($0.id) }
                }
                Toggle("全部汉字", isOn: $model.fullCharset)
            }
            if !model.fuzzy.isEmpty {
                Section {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                        ForEach(model.fuzzy, id: \.id) { group in
                            Toggle(group.title, isOn: $model.fuzzyOn[contains: group.id])
                        }
                    }
                } header: {
                    Text("模糊音")
                }
            }
            if #available(macOS 26.0, *) {
                Section {
                    Picker("翻译按键", selection: $model.translationModifier) {
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
        .needsEngine(model.ready)
    }
}

private struct AppearancePane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .appearance)
            Section {
                LabeledContent("字号") {
                    Measure(value: $model.fontSize, range: CandidateStyle.fontSizes)
                }
                LabeledContent("强调色") {
                    AccentPicker(accent: $model.accent)
                }
                LabeledContent("高亮边距") {
                    Measure(value: $model.inset, range: CandidateStyle.insets)
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
    @Binding var accent: String

    private static let systemFill = AnyShapeStyle(AngularGradient(
        colors: [.blue, .purple, .pink, .red, .orange, .yellow, .green, .blue], center: .center))
    private static let presetFills = CandidateStyle.presets.map { preset in
        (id: preset.id, name: preset.name, fill: AnyShapeStyle(Color(nsColor: CandidateStyle(accent: preset.id).accentColor)))
    }

    var body: some View {
        HStack(spacing: 4) {
            Swatch(fill: Self.systemFill, selected: accent == "system", help: "系统强调色") {
                accent = "system"
            }
            ForEach(Self.presetFills, id: \.id) { preset in
                Swatch(fill: preset.fill, selected: accent == preset.id, help: preset.name) {
                    accent = preset.id
                }
            }
            let own = CandidateStyle.color(hex: accent)
            Swatch(fill: own.map { AnyShapeStyle(Color(nsColor: $0)) }, selected: own != nil, help: "自定义颜色") {
                ColorPanel.shared.open(with: CandidateStyle(accent: accent).accentColor) { color in
                    if let hex = CandidateStyle.hex(color) { accent = hex }
                }
            }
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

/// One color to choose, ringed when chosen. With no fill, an outline with a
/// plus: a color of one's own, not yet chosen.
private struct Swatch: View {
    let fill: AnyShapeStyle?
    let selected: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let fill {
                    Circle()
                        .fill(fill)
                        .overlay(Circle().strokeBorder(.black.opacity(0.12)))
                } else {
                    Circle()
                        .strokeBorder(.secondary.opacity(0.6), lineWidth: 1)
                        .overlay(Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary))
                }
            }
            .frame(width: 16, height: 16)
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
    let model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .apps)
            if !model.apps.isEmpty {
                Section {
                    ForEach(model.apps) { app in
                        Button { model.openApp = app.id } label: {
                            HStack(spacing: 10) {
                                Image(nsImage: model.icon(for: app.id, side: 28))
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
    let model: SettingsModel
    let entry: AppRules.Entry

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    HStack {
                        Button { model.openApp = nil } label: {
                            Label(Pane.apps.title, systemImage: "chevron.backward")
                        }
                        .buttonStyle(.borderless)
                        Spacer()
                    }
                    Image(nsImage: model.icon(for: entry.id, side: 54))
                        .frame(width: 54, height: 54)
                    Text(entry.name)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            Section {
                Picker("标点样式", selection: rule(\.halfwidthPunctuation)) {
                    Text(AppRules.Entry.followDefault).tag(false)
                    Text(AppRules.Entry.halfwidth).tag(true)
                }
            }
            Section {
                Toggle("不学习用户输入行为", isOn: rule(\.noLearn))
            } footer: {
                Note("开启后，OctoDot 不会从你在此应用中的输入和选词学习。已学词条仍可使用。")
            }
            Section {
                Button("移除", role: .destructive) { model.removeApp(entry.id) }
            }
        }
        .formStyle(.grouped)
    }

    /// One of this app's rules, stored as soon as it changes.
    private func rule(_ keyPath: WritableKeyPath<AppRules.Entry, Bool>) -> Binding<Bool> {
        Binding {
            guard let current = model.openEntry, current.id == entry.id else { return entry[keyPath: keyPath] }
            return current[keyPath: keyPath]
        } set: { on in
            guard var changed = model.openEntry, changed.id == entry.id else { return }
            changed[keyPath: keyPath] = on
            model.openEntry = changed
        }
    }
}

private struct LexiconPane: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .lexicon)
            Section("万象词库") {
                ForEach(model.sets, id: \.id) { set in
                    Toggle(set.name, isOn: $model.mountedSets[contains: set.id])
                }
                Toggle("英文单词", isOn: $model.english)
            }
            Section {
                LabeledContent("自定义短语") {
                    Button("编辑…") { model.editPhrases() }
                }
            }
        }
        .formStyle(.grouped)
        .needsEngine(model.ready)
    }
}

private struct PrivacyPane: View {
    @Bindable var model: SettingsModel
    @State private var confirmingEverything = false

    var body: some View {
        Form {
            PaneHeader(pane: .privacy)
            Section {
                Toggle("无痕模式", isOn: $model.incognito)
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

private extension View {
    /// A pane whose rows come from the engine: greyed out, under a note,
    /// while the engine has not loaded its images.
    func needsEngine(_ ready: Bool) -> some View {
        disabled(!ready).overlay { if !ready { NotReady() } }
    }
}
