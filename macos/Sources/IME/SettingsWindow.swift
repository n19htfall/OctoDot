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
        model.onPane = nil
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
        window.title = Pane.input.title
        model.onPane = { [weak window] pane in window?.title = pane.title }
        window.setContentSize(NSSize(width: 720, height: 520))
        window.contentMinSize = NSSize(width: 640, height: 440)
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
}

/// The window's panes, as System Settings shows its own: a colored tile, a
/// title, and what the pane is for.
enum Pane: String, CaseIterable, Identifiable, Sendable {
    case input, appearance, lexicon, privacy

    var id: Self { self }

    var title: String {
        switch self {
        case .input: "Input"
        case .appearance: "Appearance"
        case .lexicon: "Lexicon"
        case .privacy: "Privacy"
        }
    }

    var symbol: String {
        switch self {
        case .input: "keyboard.fill"
        case .appearance: "paintpalette.fill"
        case .lexicon: "books.vertical.fill"
        case .privacy: "hand.raised.fill"
        }
    }

    var tint: Color {
        switch self {
        case .input: .gray
        case .appearance: .purple
        case .lexicon: .orange
        case .privacy: .blue
        }
    }

    var blurb: String {
        switch self {
        case .input: "How your keys become Chinese: the scheme you type in, shape codes, and how sentences are ranked."
        case .appearance: "How the candidate window looks: the size of its text, the highlight's color, and its padding."
        case .lexicon: "The words OctoDot knows beyond its core lexicon, your own phrases among them."
        case .privacy: "What OctoDot learns from your typing, and forgetting it. Nothing you type ever leaves this Mac."
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

/// The top of a pane, as in System Settings: its tile, title and purpose.
private struct PaneHeader: View {
    let pane: Pane

    var body: some View {
        Section {
            VStack(spacing: 8) {
                PaneIcon(pane: pane, size: 54)
                Text(pane.title).font(.title2.weight(.semibold))
                Text(pane.blurb)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
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
    var grammar = Engine.GrammarState.absent
    var rerank: Bool?                           // nil: the images have no reranker
    var fullCharset = false
    var fuzzy: [Engine.FuzzyGroup] = []
    var english = true
    var englishSpace = false
    var sets: [Engine.LexiconSet] = []
    var incognito = false
    var phrases = ""
    var health: String?
    var forgot: String?
    var style = CandidateStyle.current
    var pane: Pane? = .input {
        didSet { onPane?(pane ?? .input) }
    }
    /// Told the pane shown, for the window's title.
    @ObservationIgnored var onPane: ((Pane) -> Void)?

    func refresh() {
        style = CandidateStyle.current
        incognito = Learning.incognito
        health = Health.menuLine
        ready = Engine.shared.isReady
        guard ready else { return }             // the engine's lists exist only while it runs
        schemes = Engine.shared.schemes()
        scheme = Learning.scheme
        auxSchemes = Engine.shared.auxSchemes()
        auxScheme = Learning.auxScheme
        grammar = Engine.shared.grammar
        rerank = Engine.shared.rerank
        fullCharset = Learning.fullCharset
        fuzzy = Engine.shared.fuzzyGroups()
        english = Learning.englishOn
        englishSpace = Learning.englishSpace
        sets = Engine.shared.lexiconSets()
        phrases = Phrases.statusLine
    }

    func useScheme(_ id: String) { Learning.useScheme(id); refresh() }
    func useAuxScheme(_ id: String) { Learning.useAuxScheme(id); refresh() }
    func useGrammar(_ on: Bool) { Learning.useGrammar(on); refresh() }
    func useRerank(_ on: Bool) { Learning.useRerank(on); refresh() }
    func useFullCharset(_ on: Bool) { Learning.useFullCharset(on); refresh() }
    func useFuzzy(_ id: String, on: Bool) { Learning.useFuzzy(id, on: on); refresh() }
    func useEnglish(_ on: Bool) { Learning.useEnglish(on); refresh() }
    func useEnglishSpace(_ on: Bool) { Learning.useEnglishSpace(on); refresh() }
    func useSet(_ id: String, on: Bool) { Learning.useSet(id, on: on); refresh() }
    func setIncognito(_ on: Bool) { Learning.incognito = on; refresh() }
    func editPhrases() { Phrases.edit() }

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

    func forget(_ scope: Engine.ForgetScope) {
        Learning.forget(scope)
        forgot = switch scope {
        case .lastFifteenMinutes: "Forgot what was learned in the last 15 minutes."
        case .today: "Forgot what was learned today."
        case .everything: "Forgot everything learned."
        }
    }
}

private struct InputPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .input)
            Section {
                Picker("输入方案 Scheme", selection: Binding(get: { model.scheme }, set: { model.useScheme($0) })) {
                    ForEach(model.schemes, id: \.id) { Text($0.name).tag($0.id) }
                }
                if !model.auxSchemes.isEmpty {
                    Picker("形码 Shape codes", selection: Binding(get: { model.auxScheme },
                                                                 set: { model.useAuxScheme($0) })) {
                        ForEach(model.auxSchemes, id: \.id) { Text($0.name).tag($0.id) }
                    }
                }
                Toggle("全部汉字 All characters", isOn: Binding(get: { model.fullCharset },
                                                              set: { model.useFullCharset($0) }))
            } footer: {
                Note("A change applies at once, to the next word you type. All characters offers rare ones too; Control-G switches while typing.")
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
                    Text("模糊音 Fuzzy pinyin")
                } footer: {
                    Note("Each pair counts as one sound: typing either spelling offers the words of both (with z = zh, zong gives 中 and 总). An exact spelling still ranks a little ahead. All off by default.")
                }
            }
            if model.grammar != .absent {
                Section {
                    Toggle("语法模型 Grammar model", isOn: Binding(get: { model.grammar == .on },
                                                                 set: { model.useGrammar($0) }))
                } footer: {
                    Note("Ranks whole sentences by how words go together.")
                }
            }
            if let rerank = model.rerank {
                Section {
                    Toggle("整句模型 Sentence model", isOn: Binding(get: { rerank }, set: { model.useRerank($0) }))
                } footer: {
                    Note("A small neural model, on this Mac, reads the best few sentences and puts the most natural first, a moment after you type.")
                }
            }
            Section {
                Toggle("英文单词 English words", isOn: Binding(get: { model.english }, set: { model.useEnglish($0) }))
                Toggle("英文后加空格 Space after English words",
                       isOn: Binding(get: { model.englishSpace }, set: { model.useEnglishSpace($0) }))
            } footer: {
                Note("Offers an English word beside the Chinese. It comes first when the letters have no Chinese reading, or you type a capital. A space is added between English words only when you ask.")
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
                LabeledContent("字号 Font size") {
                    Measure(value: Binding(get: { Double(model.style.fontSize) }, set: { model.setFontSize($0) }),
                            range: CandidateStyle.fontSizes)
                }
                LabeledContent("强调色 Accent color") {
                    AccentPicker(model: model)
                }
                LabeledContent("高亮边距 Highlight padding") {
                    Measure(value: Binding(get: { Double(model.style.inset) }, set: { model.setInset($0) }),
                            range: CandidateStyle.insets)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 12) {
                    Note("Highlight padding is the space between the highlighted candidate and the window's edge.")
                    HStack {
                        Spacer()
                        Button("Restore Defaults") { model.resetAppearance() }
                            .disabled(model.style == CandidateStyle())
                    }
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
                   selected: model.style.accent == "system", help: "System accent color") {
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
            .help("A color of your own")
            .accessibilityLabel("A color of your own")
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

private struct LexiconPane: View {
    let model: SettingsModel

    var body: some View {
        Form {
            PaneHeader(pane: .lexicon)
            if !model.sets.isEmpty {
                Section("词库 Lexicon sets") {
                    ForEach(model.sets, id: \.id) { set in
                        Toggle(set.name, isOn: Binding(get: { set.mounted }, set: { model.useSet(set.id, on: $0) }))
                    }
                }
            }
            Section {
                LabeledContent("自定义短语 Custom phrases") {
                    Button("Edit…") { model.editPhrases() }
                }
            } footer: {
                Note(model.phrases)
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
                Toggle("Incognito: learn nothing", isOn: Binding(get: { model.incognito },
                                                                  set: { model.setIncognito($0) }))
            } footer: {
                Note("While it is on, nothing you type teaches the dictionary. "
                     + "Password fields and password managers never do.")
            }
            Section {
                LabeledContent("The last 15 minutes") {
                    Button("Forget") { model.forget(.lastFifteenMinutes) }
                }
                LabeledContent("Today") {
                    Button("Forget") { model.forget(.today) }
                }
                LabeledContent("Everything") {
                    Button("Forget…", role: .destructive) { confirmingEverything = true }
                }
            } header: {
                Text("Forget what was learned")
            } footer: {
                if let forgot = model.forgot {
                    Note(forgot)
                } else if let health = model.health {
                    Note(health)
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Forget everything OctoDot learned?", isPresented: $confirmingEverything) {
            Button("Forget Everything", role: .destructive) { model.forget(.everything) }
        } message: {
            Text("The words and phrases it learned from your typing are deleted. This cannot be undone.")
        }
    }
}

/// A section's explanation, under it and aligned with its rows, as in System Settings.
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
        Text("The lexicon did not load, so typing passes through unchanged.")
            .foregroundStyle(.secondary)
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
