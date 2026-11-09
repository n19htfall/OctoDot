import AppKit
import Carbon.HIToolbox
import InputMethodKit

/// One instance per client text input, made by this core for the launcher's
/// controller of that client (Sources/Launcher), which passes IMK's calls on.
/// IMK calls on the main thread, but its methods are not annotated as
/// main-actor isolated, so every engine call goes through
/// `MainActor.assumeIsolated`. That traps at once if the thread is ever
/// wrong, instead of breaking Goose's same-thread rule silently. The closures
/// capture only Sendable values; IMK's client objects stay outside.
final class Handler: NSObject, OctoDotHandler {
    private weak var controller: IMKInputController?
    private var session: Engine.Session?
    private var clientApp = ""
    /// Where the panel was last placed, and which showing that was: a late
    /// answer from the client must not move a panel shown again since.
    private var anchorRect = NSRect.zero
    private var anchorGeneration = 0
    /// A key's snapshot whose candidates wait for the reranker
    /// (`Engine.KeyResult.pending`), shown as they are if it changes nothing.
    private var waiting: Snapshot?

    private static let notFound = NSRange(location: NSNotFound, length: NSNotFound)

    /// Handlers alive now, one per IMK controller that has been used. IMK
    /// never frees a controller whose client proxy it replaced (a Caps Lock
    /// toggle makes a new proxy, and so a new controller), so this only
    /// grows; the count is logged to see by how much. A handler holds an
    /// engine session only from its first key to its deactivation, so the
    /// controllers IMK abandons hold none. Main thread only.
    nonisolated(unsafe) private static var live = 0

    init(controller: IMKInputController) {
        self.controller = controller
        clientApp = controller.client()?.bundleIdentifier() ?? ""
        super.init()
        Self.live += 1
        let live = Self.live
        log.notice("client handlers alive: \(live, privacy: .public)")
    }

    /// The engine session, made at the first key after an activation.
    private func activeSession() -> Engine.Session? {
        if let session { return session }
        let app = clientApp
        let made = MainActor.assumeIsolated { () -> Engine.Session? in
            Engine.shared.isStarted ? Engine.shared.newSession(clientBundleID: app) : nil
        }
        session = made
        return made
    }

    private func client() -> (any IMKTextInput)? { controller?.client() }

    /// The core is being replaced: a composition in progress ends as on a
    /// focus change, and the session goes while the engine is still there.
    func retire() {
        guard let session else { return }
        if MainActor.assumeIsolated({ Engine.shared.snapshot(session).isComposing }) {
            deactivate(client())
        }
        MainActor.assumeIsolated { Engine.shared.free(session) }
        self.session = nil
    }

    deinit {
        Self.live -= 1
        if let session {
            Task { @MainActor in Engine.shared.free(session) }
        }
    }

    /// Key presses only: no modifier alone does anything. (A Shift tap used to
    /// switch to English, and a Shift-click, which the IME cannot see, could
    /// switch it unnoticed; there is no English mode now.)
    func eventMask(for sender: Any?) -> UInt {
        UInt(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    func handleKey(_ event: NSEvent?, client sender: Any?) -> Bool {
        guard let event, let client = sender as? any IMKTextInput, event.type == .keyDown,
              let session = activeSession()
        else {
            return false
        }
        if let arrow = Self.emacsNavigation(event),
           MainActor.assumeIsolated({ Engine.shared.snapshot(session).isComposing }) {
            return run(TranslatedKey(key: arrow, codepoint: 0, modifiers: []), session, client)
        }
        return run(Self.translate(event), session, client)
    }

    private static func emacsNavigation(_ event: NSEvent) -> Engine.Key? {
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        guard flags == .control, let raw = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch raw {
        case "n": return .down
        case "p": return .up
        case "f": return .right
        case "b": return .left
        case "a": return .home
        case "e": return .end
        default: return nil
        }
    }

    private func run(_ key: TranslatedKey, _ session: Engine.Session, _ client: any IMKTextInput,
                     extra: Engine.KeyFlags = []) -> Bool {
        settle(session)
        let app = clientApp
        let (result, snapshot) = MainActor.assumeIsolated {
            let outcome = Engine.shared.process(session, key, flags: Learning.flags(forApp: app).union(extra))
            Learning.noteActivity()
            return outcome
        }
        guard let snapshot else { return result.contains(.handled) }
        showText(snapshot, in: client)
        if result.contains(.pending) {
            // The reranker may reorder the menu: the candidates wait for it,
            // after this returns (the app typed in never waits) and the
            // preedit is on screen, and are shown once, in their final order.
            waiting = snapshot
            let box = ControllerBox(self)
            DispatchQueue.main.async { MainActor.assumeIsolated { box.controller?.showReranked() } }
        } else {
            waiting = nil
            showCandidates(snapshot, in: client)
        }
        return result.contains(.handled)
    }

    /// The candidates of the key whose result was `.pending`, reranked (a few
    /// milliseconds), or as they were if the reranker changed nothing.
    fileprivate func showReranked() {
        guard let snapshot = waiting, let session, let client = client() else { return }
        waiting = nil
        let reranked = MainActor.assumeIsolated { Engine.shared.refine(session).1 }
        showCandidates(reranked ?? snapshot, in: client)
    }

    /// A key came before the last one's candidates were shown: the menu is
    /// reranked first, so the key acts on what would have been shown (Space
    /// picks the reranked sentence). The key then shows its own.
    private func settle(_ session: Engine.Session) {
        guard waiting != nil else { return }
        waiting = nil
        _ = MainActor.assumeIsolated { Engine.shared.refine(session) }
    }

    // MARK: The input menu

    /// Everything to set lives in the settings window; updates are the
    /// companion app's (the IME has no network), which the item opens.
    func inputMenu() -> NSMenu? {
        let menu = NSMenu()
        for (title, tag) in [("八千点 - 设置", MenuItem.settings), ("八千点 - 检查更新", MenuItem.updates)] {
            let entry = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = tag.rawValue
            menu.addItem(entry)
        }
        return menu
    }

    private enum MenuItem: Int { case settings = 1, updates = 2 }

    /// IMK sends menu actions to the controller, with a dictionary holding the
    /// menu item; the controller passes them here.
    func chooseMenuItem(_ sender: Any?) { menuAction(sender) }

    /// The item's own action, should a menu ever call its target directly.
    @objc func menuAction(_ sender: Any?) {
        let item = (sender as? NSMenuItem)
            ?? ((sender as? [String: Any])?[kIMKCommandMenuItemName] as? NSMenuItem)
        let updates = item?.tag == MenuItem.updates.rawValue
        MainActor.assumeIsolated {
            if updates { Companion.open("update") } else { SettingsWindow.show() }
        }
    }

    /// The client is about to lose the composition (focus moved, the user
    /// clicked elsewhere): commit what was typed rather than dropping it.
    func commitComposition(for sender: Any?) {
        guard let session, let client = sender as? any IMKTextInput else { return }
        let snapshot = MainActor.assumeIsolated { () -> Snapshot? in
            guard Engine.shared.snapshot(session).isComposing else { return nil }
            return Engine.shared.process(session, .special(.enter)).1
        }
        if let snapshot { show(snapshot, in: client) }
    }

    func activate(_ sender: Any?) {
        MainActor.assumeIsolated { Phrases.refreshIfChanged() }
    }

    /// The client lost focus, or its controller is being abandoned (IMK
    /// never says which): the composition ends and the session goes. The
    /// next key makes a new one.
    func deactivate(_ sender: Any?) {
        anchorGeneration &+= 1                  // no late move after the panel is gone
        waiting = nil                           // nor late candidates
        if let session {
            MainActor.assumeIsolated {
                Engine.shared.free(session)
                CandidatePanel.shared.hide()
                Learning.saveNow()
            }
            self.session = nil
        }
        (sender as? any IMKTextInput)?.setMarkedText(
            "", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.notFound)
    }

    private func show(_ snapshot: Snapshot, in client: any IMKTextInput) {
        waiting = nil
        showText(snapshot, in: client)
        showCandidates(snapshot, in: client)
    }

    /// What the key committed, and the preedit.
    private func showText(_ snapshot: Snapshot, in client: any IMKTextInput) {
        if !snapshot.commit.isEmpty {
            client.insertText(snapshot.commit, replacementRange: Self.notFound)
        }
        let caret = snapshot.preedit.utf8.index(snapshot.preedit.utf8.startIndex, offsetBy: snapshot.caretUTF8)
        let caretUTF16 = snapshot.preedit.utf16.distance(from: snapshot.preedit.startIndex, to: caret)
        let marked = NSAttributedString(string: snapshot.preedit, attributes: [
            .underlineStyle: NSUnderlineStyle.thick.rawValue,
            .underlineColor: NSColor.controlAccentColor,
        ])
        client.setMarkedText(marked, selectionRange: NSRange(location: caretUTF16, length: 0),
                             replacementRange: Self.notFound)
    }

    /// The candidate window, at the composition.
    private func showCandidates(_ snapshot: Snapshot, in client: any IMKTextInput) {
        var lineRect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
        let page = CandidatePanel.Page(snapshot)
        let box = ControllerBox(self)
        anchorRect = lineRect
        anchorGeneration &+= 1
        let generation = anchorGeneration
        MainActor.assumeIsolated {
            CandidatePanel.shared.onAction = { action in box.controller?.panelAction(action) }
            CandidatePanel.shared.show(page, near: lineRect)
        }
        // Clients that lay text out asynchronously (Chrome, Electron apps,
        // web views) answer with the composition's previous place right
        // after setMarkedText, which leaves the panel behind, most visibly
        // when a new composition starts after a commit. Ask again shortly,
        // and follow.
        guard !page.candidates.isEmpty else { return }
        for delay in [0.03, 0.1, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { box.controller?.reanchor(generation) }
            }
        }
    }

    fileprivate func reanchor(_ generation: Int) {
        guard generation == anchorGeneration, let client = self.client() else { return }
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
        guard rect != .zero, rect != anchorRect else { return }
        anchorRect = rect
        MainActor.assumeIsolated { CandidatePanel.shared.move(near: rect) }
    }

    /// A click in the candidate window: the same as the key for it.
    fileprivate func panelAction(_ action: CandidatePanel.Action) {
        guard let session, let client = self.client() else { return }
        switch action {
        case .pick(let position):
            let page = MainActor.assumeIsolated { Engine.shared.snapshot(session).page }
            let index = page * Snapshot.columns + position
            guard index >= 0 else { return }
            _ = run(TranslatedKey(key: .other, codepoint: UInt32(index), modifiers: []), session, client, extra: .pick)
        case .previousPage:
            _ = run(.special(.pageUp), session, client)
        case .nextPage:
            _ = run(.special(.pageDown), session, client)
        case .row(let delta):
            guard delta != 0 else { return }
            if delta < 0 {
                let snap = MainActor.assumeIsolated { Engine.shared.snapshot(session) }
                if snap.isExpanded && !snap.hasPreviousPage && snap.highlighted < Snapshot.columns { return }
            }
            _ = run(.special(delta < 0 ? .up : .down), session, client)
        }
    }

    private static func translate(_ event: NSEvent) -> TranslatedKey {
        let key: Engine.Key = switch Int(event.keyCode) {
        case kVK_Delete: .backspace
        case kVK_Escape: .escape
        case kVK_Return, kVK_ANSI_KeypadEnter: .enter
        case kVK_Space: .space
        case kVK_LeftArrow: .left
        case kVK_RightArrow: .right
        case kVK_UpArrow: .up
        case kVK_DownArrow: .down
        case kVK_PageUp: .pageUp
        case kVK_PageDown: .pageDown
        default: .other
        }
        let flags = event.modifierFlags
        // With Control held, `characters` is a control code (Control-g is BEL),
        // so the engine gets the key's own character instead.
        let typed = flags.contains(.control) ? event.charactersIgnoringModifiers : event.characters
        let codepoint = key == .other ? typed?.unicodeScalars.first?.value ?? 0 : 0
        var modifiers: Engine.Modifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return TranslatedKey(key: key, codepoint: codepoint, modifiers: modifiers)
    }
}

/// The candidate window's clicks come back on the main thread, to whichever
/// controller showed it last. IMK's controller is not Sendable, so it travels
/// in a weak box that only main-thread code unwraps.
private final class ControllerBox: @unchecked Sendable {
    weak var controller: Handler?
    init(_ controller: Handler) { self.controller = controller }
}
