import Foundation
import os

/// The companion's line to its installer (Contents/XPCServices): each call
/// as an async function. The connection checks the service's signature too,
/// so the companion only ever talks to its own team's installer.
@MainActor
final class InstallerClient {
    static let shared = InstallerClient()
    private var connection: NSXPCConnection?

    private func proxy(_ failed: @escaping @Sendable () -> Void) -> (any InstallerProtocol)? {
        let connection = self.connection ?? connect()
        return connection.remoteObjectProxyWithErrorHandler { _ in failed() } as? any InstallerProtocol
    }

    private func connect() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: Identity.installer)
        connection.remoteObjectInterface = NSXPCInterface(with: InstallerProtocol.self)
        connection.setCodeSigningRequirement(
            "anchor apple generic and certificate leaf[subject.OU] = \"\(Identity.team)\" and identifier \"\(Identity.installer)\"")
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    /// One call: `body` sends it with a reply that resumes the caller;
    /// `fallback` if the service is unreachable. A reply and a failure never
    /// both resume it.
    private func call<T: Sendable>(_ fallback: T,
                                   _ body: (any InstallerProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { continuation in
            let once = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (T) -> Void = { value in
                let first = once.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: value) }
            }
            guard let proxy = proxy({ finish(fallback) }) else {
                finish(fallback)
                return
            }
            body(proxy, finish)
        }
    }

    func facts() async -> SetupFacts? {
        let data: Data? = await call(nil) { proxy, done in proxy.facts { done($0) } }
        return data.flatMap { try? JSONDecoder().decode(SetupFacts.self, from: $0) }
    }

    func installIME() async -> (Bool, String) {
        let r: Outcome = await call(.unreachable) { proxy, done in proxy.installIME { done(Outcome($0, $1)) } }
        return (r.ok, r.message)
    }

    func enableIME() async -> Bool { await call(false) { proxy, done in proxy.enableIME { done($0) } } }
    func isEnabled() async -> Bool { await call(false) { proxy, done in proxy.isEnabled { done($0) } } }
    func selectIME() async -> Bool { await call(false) { proxy, done in proxy.selectIME { done($0) } } }
    func launchIME() async -> Bool { await call(false) { proxy, done in proxy.launchIME { done($0) } } }

    func preflight() async -> Preflight? {
        let data: Data? = await call(nil) { proxy, done in proxy.preflight { done($0) } }
        return data.flatMap { try? JSONDecoder().decode(Preflight.self, from: $0) }
    }

    func exportUserData() async -> Transfer? {
        let data: Data? = await call(nil) { proxy, done in proxy.exportUserData { done($0) } }
        return data.flatMap { try? JSONDecoder().decode(Transfer.self, from: $0) }
    }

    func importUserData(_ transfer: Transfer) async -> (Bool, String) {
        guard let data = try? JSONEncoder().encode(transfer) else { return (false, "Could not prepare the data.") }
        let r: Outcome = await call(.unreachable) { proxy, done in
            proxy.importUserData(data) { done(Outcome($0, $1)) }
        }
        return (r.ok, r.message)
    }

    func copyToApplications() async -> (Bool, String) {
        let r: Outcome = await call(.unreachable) { proxy, done in proxy.copyToApplications { done(Outcome($0, $1)) } }
        return (r.ok, r.message)
    }

    func installUpdate(manifest: Data, file: FileHandle) async -> (Bool, String) {
        let r: Outcome = await call(.unreachable) { proxy, done in
            proxy.installUpdate(manifest: manifest, file: file) { done(Outcome($0, $1)) }
        }
        return (r.ok, r.message)
    }

    func uninstall(wipe: Bool) async -> (Bool, String) {
        let r: Outcome = await call(.unreachable) { proxy, done in
            proxy.uninstall(wipe: wipe) { done(Outcome($0, $1)) }
        }
        return (r.ok, r.message)
    }
}

/// A reply of the installer's: whether it worked, and what to tell the user.
struct Outcome: Sendable {
    var ok: Bool
    var message: String
    init(_ ok: Bool, _ message: String) {
        self.ok = ok
        self.message = message
    }
    static let unreachable = Outcome(false, "OctoDot's installer did not answer.")
}

/// The IME's --preflight.
struct Preflight: Codable, Sendable {
    var sandboxed: Bool
    var container: Bool
    var appGroup: Bool
    var keychain: Bool
    var images: Bool
    var ok: Bool
}
