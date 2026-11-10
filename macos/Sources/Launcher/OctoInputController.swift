import AppKit
import InputMethodKit

/// One per client text input, made by IMKServer (Info.plist names it in
/// InputMethodServerControllerClass). It lives as long as the client's
/// connection, across core reloads, and passes every call to a handler from
/// the core loaded now: after a reload, the next call makes a new one.
@objc(OctoInputController)
final class OctoInputController: IMKInputController {
    private var handler: (any OctoDotHandler)?
    private var generation = 0                  // Launcher.generation counts from 1

    override init!(server: IMKServer!, delegate: Any!, client inputClient: Any!) {
        super.init(server: server, delegate: delegate, client: inputClient)
        Launcher.controllers.add(self)
    }

    /// The handler from the core in use, made on first use after each load.
    /// None while no core loaded: then keys go to the app as typed.
    private var current: (any OctoDotHandler)? {
        if generation != Launcher.generation {
            handler = Launcher.core?.handler(for: self)
            generation = Launcher.generation
        }
        return handler
    }

    /// Before the core is replaced.
    func canRetire() -> Bool {
        guard let handler else { return true }
        guard let handler = handler as? any OctoDotHandlerV2 else { return false }
        return !handler.hasActiveComposition()
    }

    func retire() {
        handler?.retire()
        handler = nil
        generation = 0
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(current?.eventMask(for: sender) ?? UInt(NSEvent.EventTypeMask.keyDown.rawValue))
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        current?.handleKey(event, client: sender) ?? false
    }

    override func menu() -> NSMenu! {
        current?.inputMenu() ?? NSMenu()
    }

    /// IMK sends input menu actions to the controller.
    @objc func menuAction(_ sender: Any?) {
        current?.chooseMenuItem(sender)
    }

    override func commitComposition(_ sender: Any!) {
        current?.commitComposition(for: sender)
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        current?.activate(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        current?.deactivate(sender)
        super.deactivateServer(sender)
    }
}
