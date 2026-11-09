import Foundation

/// OctoDot's installer: an XPC service inside the companion
/// (Contents/XPCServices), not sandboxed and with no network, which only the
/// companion it ships in may call (Installer.swift).
final class Listener: NSObject, NSXPCListenerDelegate {
    let installer = Installer()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Only OctoDot's companion, signed by its team: macOS checks the
        // caller's signature before any message is delivered.
        connection.setCodeSigningRequirement(Signatures.requirement(Identity.companion))
        connection.exportedInterface = NSXPCInterface(with: InstallerProtocol.self)
        connection.exportedObject = installer
        connection.resume()
        return true
    }
}

let delegate = Listener()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
