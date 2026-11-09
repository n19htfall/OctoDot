import AppKit
import Carbon.HIToolbox
import InputMethodKit

/// One instance per client text input. IMK calls it on the main thread, but
/// its methods are not annotated as main-actor isolated, so every engine call
/// goes through `MainActor.assumeIsolated`. That traps immediately if the
/// thread is ever wrong, instead of breaking Goose's same-thread rule
/// silently. The closures capture only Sendable values; IMK's client objects
/// stay outside them.
@objc(OctoInputController)
final class OctoInputController: IMKInputController {
    private var session: Engine.Session?

    private static let notFound = NSRange(location: NSNotFound, length: NSNotFound)

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        let bundleID = (inputClient as? any IMKTextInput)?.bundleIdentifier() ?? ""
        session = MainActor.assumeIsolated { Engine.shared.newSession(clientBundleID: bundleID) }
    }

    deinit {
        if let session {
            Task { @MainActor in Engine.shared.free(session) }
        }
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let session,
              let client = sender as? any IMKTextInput
        else { return false }
        let key = Self.translate(event)
        let (result, snapshot) = MainActor.assumeIsolated { Engine.shared.process(session, key) }
        if let snapshot { show(snapshot, in: client) }
        return result.contains(.handled)
    }

    override func deactivateServer(_ sender: Any!) {
        // M0 discards an unfinished composition when focus leaves.
        if let session {
            MainActor.assumeIsolated {
                Engine.shared.reset(session)
                CandidatePanel.shared.hide()
            }
        }
        (sender as? any IMKTextInput)?.setMarkedText(
            "", selectionRange: NSRange(location: 0, length: 0), replacementRange: Self.notFound)
        super.deactivateServer(sender)
    }

    private func show(_ snapshot: Snapshot, in client: any IMKTextInput) {
        if !snapshot.commit.isEmpty {
            client.insertText(snapshot.commit, replacementRange: Self.notFound)
        }
        let caret = snapshot.preedit.utf8.index(snapshot.preedit.utf8.startIndex,
                                                offsetBy: snapshot.caretUTF8)
        let caretUTF16 = snapshot.preedit.utf16.distance(from: snapshot.preedit.startIndex, to: caret)
        let marked = NSAttributedString(string: snapshot.preedit, attributes: [
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ])
        client.setMarkedText(marked, selectionRange: NSRange(location: caretUTF16, length: 0),
                             replacementRange: Self.notFound)

        var lineRect = NSRect.zero
        _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &lineRect)
        let candidates = snapshot.candidates
        let highlighted = snapshot.highlighted
        MainActor.assumeIsolated {
            CandidatePanel.shared.update(candidates: candidates, highlighted: highlighted, near: lineRect)
        }
    }

    private static func translate(_ event: NSEvent) -> TranslatedKey {
        let key: Engine.Key = switch Int(event.keyCode) {
        case kVK_Delete: .backspace
        case kVK_Escape: .escape
        case kVK_Return, kVK_ANSI_KeypadEnter: .enter
        case kVK_Space: .space
        default: .other
        }
        let codepoint = event.characters?.unicodeScalars.first?.value ?? 0
        var modifiers: Engine.Modifiers = []
        let flags = event.modifierFlags
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return TranslatedKey(key: key, codepoint: codepoint, modifiers: modifiers)
    }
}
