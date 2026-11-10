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
final class Handler: NSObject, OctoDotHandlerV2 {
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

    /// A hot reload waits for a composition to end naturally.
    func hasActiveComposition() -> Bool {
        guard let session else { return false }
        return MainActor.assumeIsolated { Engine.shared.snapshot(session).isComposing }
    }

    /// The launcher has checked that there is no active composition.
    func retire() {
        OptionChords.release(ObjectIdentifier(self))
        guard let session else { return }
        // Termination can also retire a handler, without a reload's wait.
        if hasActiveComposition() { commitComposition(for: client()) }
        MainActor.assumeIsolated { Engine.shared.free(session) }
        self.session = nil
    }

    deinit {
        let id = ObjectIdentifier(self)
        if Thread.isMainThread {
            MainActor.assumeIsolated { OptionChords.release(id) }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { OptionChords.release(id) } }
        }
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
        if event.modifierFlags.intersection([.shift, .control, .option, .command]) == .option,
           let plain = Self.optionCandidateKey(event),
           MainActor.assumeIsolated({ Engine.shared.snapshot(session).isComposing }) {
            if OptionChords.recentlyHandled(event.keyCode) { return true }
            return run(plain, session, client, replaceSelection: Self.isDigitSelection(plain))
        }
        if let arrow = Self.emacsNavigation(event),
           MainActor.assumeIsolated({ Engine.shared.snapshot(session).isComposing }) {
            return run(TranslatedKey(key: arrow, codepoint: 0, modifiers: []), session, client)
        }
        return run(Self.translate(event), session, client)
    }

    private static func optionCandidateKey(_ event: NSEvent) -> TranslatedKey? {
        switch Int(event.keyCode) {
        case kVK_PageUp: return .special(.pageUp)
        case kVK_PageDown: return .special(.pageDown)
        default: break
        }
        guard let raw = event.charactersIgnoringModifiers, raw.count == 1, let c = raw.first else { return nil }
        switch c {
        case "1", "2", "3", "4", "5", "6", "-", "=": return .character(c)
        default: return nil
        }
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
                     extra: Engine.KeyFlags = [], replaceSelection: Bool = false) -> Bool {
        settle(session)
        if replaceSelection {
            MainActor.assumeIsolated {
                let snap = Engine.shared.snapshot(session)
                if let candidate = Self.selectedCandidate(key, snap, pick: extra.contains(.pick)),
                   let text = CandidatePanel.machineTranslation(of: candidate) {
                    Engine.shared.armPickText(session, text)
                }
            }
        }
        defer { syncOptionChords(session) }
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
        syncOptionChords(session)
    }

    func activate(_ sender: Any?) {
        MainActor.assumeIsolated { Phrases.refreshIfChanged() }
    }

    /// The client lost focus, or its controller is being abandoned (IMK
    /// never says which): the composition ends and the session goes. The
    /// next key makes a new one.
    func deactivate(_ sender: Any?) {
        OptionChords.release(ObjectIdentifier(self))
        anchorGeneration &+= 1                  // no late move after the panel is gone
        waiting = nil                           // nor late candidates
        if let session {
            MainActor.assumeIsolated {
                Engine.shared.free(session)
                CandidatePanel.shared.hide()
                CandidatePanel.clearTranslations()
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
        let app = clientApp
        anchorRect = lineRect
        anchorGeneration &+= 1
        let generation = anchorGeneration
        MainActor.assumeIsolated {
            CandidatePanel.shared.onAction = { action in box.controller?.panelAction(action) }
            CandidatePanel.shared.show(page, near: lineRect, clientApp: app)
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
            let replace = NSEvent.modifierFlags.contains(.option)
            _ = run(TranslatedKey(key: .other, codepoint: UInt32(index), modifiers: []), session, client,
                    extra: .pick, replaceSelection: replace)
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

    private static func isDigitSelection(_ key: TranslatedKey) -> Bool {
        guard key.key == .other, let scalar = Unicode.Scalar(key.codepoint) else { return false }
        let one = Unicode.Scalar("1").value
        return scalar.value >= one && scalar.value < one + UInt32(Snapshot.columns)
    }

    private static func selectedCandidate(_ key: TranslatedKey, _ snap: Snapshot, pick: Bool) -> String? {
        let index: Int
        if pick {
            index = Int(key.codepoint) - snap.page * Snapshot.columns
        } else {
            guard isDigitSelection(key), let scalar = Unicode.Scalar(key.codepoint) else { return nil }
            let digit = Int(scalar.value - Unicode.Scalar("1").value)
            index = (snap.highlighted / Snapshot.columns) * Snapshot.columns + digit
        }
        guard snap.candidates.indices.contains(index) else { return nil }
        return snap.candidates[index].text
    }

    fileprivate func performOptionChord(_ key: TranslatedKey) {
        guard let session, let client = client() else {
            OptionChords.release(ObjectIdentifier(self))
            return
        }
        let composing = MainActor.assumeIsolated { Engine.shared.snapshot(session).isComposing }
        guard composing else {
            OptionChords.release(ObjectIdentifier(self))
            return
        }
        _ = run(key, session, client, replaceSelection: Self.isDigitSelection(key))
    }

    private func syncOptionChords(_ session: Engine.Session) {
        let composing = MainActor.assumeIsolated { Engine.shared.snapshot(session).isComposing }
        if composing { OptionChords.acquire(self) }
        else { OptionChords.release(ObjectIdentifier(self)) }
    }
}

private struct OptionChord {
    var keyCode: UInt32
    var id: UInt32
    var key: TranslatedKey
}

private enum OptionChords {
    private static let signature: OSType = 0x4F63746F
    private static let chords: [OptionChord] = [
        .init(keyCode: UInt32(kVK_ANSI_1), id: 1, key: .character("1")),
        .init(keyCode: UInt32(kVK_ANSI_2), id: 2, key: .character("2")),
        .init(keyCode: UInt32(kVK_ANSI_3), id: 3, key: .character("3")),
        .init(keyCode: UInt32(kVK_ANSI_4), id: 4, key: .character("4")),
        .init(keyCode: UInt32(kVK_ANSI_5), id: 5, key: .character("5")),
        .init(keyCode: UInt32(kVK_ANSI_6), id: 6, key: .character("6")),
        .init(keyCode: UInt32(kVK_ANSI_Minus), id: 7, key: .character("-")),
        .init(keyCode: UInt32(kVK_ANSI_Equal), id: 8, key: .character("=")),
        .init(keyCode: UInt32(kVK_PageUp), id: 9, key: .special(.pageUp)),
        .init(keyCode: UInt32(kVK_PageDown), id: 10, key: .special(.pageDown)),
        .init(keyCode: UInt32(kVK_ANSI_Keypad1), id: 11, key: .character("1")),
        .init(keyCode: UInt32(kVK_ANSI_Keypad2), id: 12, key: .character("2")),
        .init(keyCode: UInt32(kVK_ANSI_Keypad3), id: 13, key: .character("3")),
        .init(keyCode: UInt32(kVK_ANSI_Keypad4), id: 14, key: .character("4")),
        .init(keyCode: UInt32(kVK_ANSI_Keypad5), id: 15, key: .character("5")),
        .init(keyCode: UInt32(kVK_ANSI_Keypad6), id: 16, key: .character("6")),
        .init(keyCode: UInt32(kVK_ANSI_KeypadMinus), id: 17, key: .character("-")),
        .init(keyCode: UInt32(kVK_ANSI_KeypadEquals), id: 18, key: .character("=")),
    ]

    nonisolated(unsafe) private static var refs: [EventHotKeyRef] = []
    nonisolated(unsafe) private static var handler: EventHandlerRef?
    nonisolated(unsafe) private static weak var owner: Handler?
    nonisolated(unsafe) private static var ownerID: ObjectIdentifier?
    nonisolated(unsafe) private static var reported = false
    nonisolated(unsafe) private static var blocked = false
    nonisolated(unsafe) private static var handledKey: UInt32 = .max
    nonisolated(unsafe) private static var handledAt: TimeInterval = 0
    nonisolated(unsafe) private static var repeatTimer: Timer?
    nonisolated(unsafe) private static var repeating: TranslatedKey?
    nonisolated(unsafe) private static var repeatingID: UInt32 = 0
    nonisolated(unsafe) private static var inCallback = false

    static func acquire(_ next: Handler) {
        let id = ObjectIdentifier(next)
        if ownerID == id, handler != nil || blocked { return }
        tearDown()
        owner = next
        ownerID = id
        guard install() else { return }
        var registered = 0
        for chord in chords {
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(chord.keyCode, UInt32(optionKey),
                                             EventHotKeyID(signature: signature, id: chord.id),
                                             GetApplicationEventTarget(), UInt32(kEventHotKeyExclusive), &ref)
            if status == noErr, let ref {
                refs.append(ref)
                registered += 1
            } else if !reported {
                reported = true
                log.notice("option chord hotkey status \(status, privacy: .public)")
            }
        }
        if registered == 0 {
            blocked = true
            if let handler { RemoveEventHandler(handler) }
            handler = nil
        }
    }

    static func release(_ id: ObjectIdentifier) {
        guard ownerID == id else { return }
        tearDown()
    }

    static func recentlyHandled(_ keyCode: UInt16) -> Bool {
        handledKey == UInt32(keyCode) && CACurrentMediaTime() - handledAt < 0.05
    }

    fileprivate static func deliver(_ hotKey: EventHotKeyID, released: Bool) -> OSStatus {
        inCallback = true
        defer { inCallback = false }
        guard hotKey.signature == signature, let chord = chords.first(where: { $0.id == hotKey.id }) else {
            return OSStatus(eventNotHandledErr)
        }
        if released {
            if repeatingID == chord.id { stopRepeat() }
            return noErr
        }
        guard let owner else { return noErr }
        handledKey = chord.keyCode
        handledAt = CACurrentMediaTime()
        beginRepeat(chord)
        owner.performOptionChord(chord.key)
        return noErr
    }

    private static func beginRepeat(_ chord: OptionChord) {
        stopRepeat()
        repeating = chord.key
        repeatingID = chord.id
        let timer = Timer(fire: Date().addingTimeInterval(NSEvent.keyRepeatDelay), interval: NSEvent.keyRepeatInterval,
                          repeats: true) { _ in MainActor.assumeIsolated { pump() } }
        RunLoop.main.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private static func pump() {
        guard NSEvent.modifierFlags.contains(.option), let key = repeating, let owner else {
            stopRepeat()
            return
        }
        owner.performOptionChord(key)
    }

    private static func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        repeating = nil
        repeatingID = 0
    }

    private static func install() -> Bool {
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = specs.withUnsafeMutableBufferPointer { buffer in
            InstallEventHandler(GetApplicationEventTarget(), optionChordEvent, 2, buffer.baseAddress, nil, &handler)
        }
        if status != noErr, !reported {
            reported = true
            log.notice("option chord hotkey status \(status, privacy: .public)")
        }
        return status == noErr
    }

    private static func tearDown() {
        stopRepeat()
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        let installed = handler
        handler = nil
        owner = nil
        ownerID = nil
        blocked = false
        handledKey = .max
        guard let installed else { return }
        if inCallback {
            DispatchQueue.main.async { RemoveEventHandler(installed) }
        } else {
            RemoveEventHandler(installed)
        }
    }
}

private func optionChordEvent(_ next: EventHandlerCallRef?, _ event: EventRef?,
                              _ user: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKey = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
    guard status == noErr else { return status }
    let released = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    return MainActor.assumeIsolated { OptionChords.deliver(hotKey, released: released) }
}

/// The candidate window's clicks come back on the main thread, to whichever
/// controller showed it last. IMK's controller is not Sendable, so it travels
/// in a weak box that only main-thread code unwraps.
private final class ControllerBox: @unchecked Sendable {
    weak var controller: Handler?
    init(_ controller: Handler) { self.controller = controller }
}
