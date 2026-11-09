import Foundation

/// The installer's whole interface (Sources/Installer): what the sandboxed
/// companion asks of the XPC service that may write ~/Library/Input Methods,
/// swap /Applications/OctoDot.app and call the input-source functions. Every
/// reply is one value or a message; nothing here takes a path the companion
/// chose, except an update's file, passed as an open handle and checked
/// again.
@objc protocol InstallerProtocol {
    /// SetupFacts as JSON.
    func facts(reply: @escaping (Data?) -> Void)

    /// Puts the companion's IME in ~/Library/Input Methods (atomically),
    /// registers it, and reloads the running IME (or restarts it, when its
    /// launcher changed); removes the old install (com.example) if it is
    /// there, its data left as it is. The message says what happened.
    func installIME(reply: @escaping (Bool, String) -> Void)

    /// Enables the installed IME's input source; true once it is enabled.
    func enableIME(reply: @escaping (Bool) -> Void)
    func isEnabled(reply: @escaping (Bool) -> Void)
    /// Makes it the current input source (for the wizard's test field).
    func selectIME(reply: @escaping (Bool) -> Void)

    /// The installed IME's --preflight, as its JSON.
    func preflight(reply: @escaping (Data?) -> Void)

    /// The installed IME's --export: its user dictionary, phrases and
    /// settings as a Transfer, JSON, or nil.
    func exportUserData(reply: @escaping (Data?) -> Void)

    /// The installed IME's --import, of a Transfer (JSON): a backup coming back.
    func importUserData(_ transfer: Data, reply: @escaping (Bool, String) -> Void)

    /// Copies the running companion to /Applications; the message is the new path or why not.
    func copyToApplications(reply: @escaping (Bool, String) -> Void)

    /// Verifies `manifest` (JSON, signed) and the update in `file` again,
    /// unpacks it, checks its code signature, and swaps it in for
    /// /Applications/OctoDot.app.
    func installUpdate(manifest: Data, file: FileHandle, reply: @escaping (Bool, String) -> Void)

    /// Disables the input source, quits the IME and removes it; with
    /// `wipe`, its user dictionary, phrases, key and settings first.
    func uninstall(wipe: Bool, reply: @escaping (Bool, String) -> Void)
}
