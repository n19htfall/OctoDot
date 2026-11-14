import Foundation
import os

/// A reply, cancellation, or deadline can arrive before or after the waiter
/// is installed. Only the first result goes to the caller.
private final class InstallerWait<Value: Sendable>: Sendable {
    private enum State {
        case preparing, waiting(CheckedContinuation<Value, Never>), finished(Value)
    }

    private let state = OSAllocatedUnfairLock(initialState: State.preparing)

    @MainActor
    func wait(for timeout: Duration?, returning fallback: Value,
              start: (_ reply: @escaping @Sendable (Value) -> Void) -> Void) async -> Value {
        let deadline = timeout.map { duration in
            Task {
                do {
                    try await Task.sleep(for: duration)
                    finish(fallback)
                } catch is CancellationError {
                    return
                }
            }
        }
        defer { deadline?.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let completed = state.withLock { state -> Value? in
                    if case .finished(let value) = state { return value }
                    state = .waiting(continuation)
                    return nil
                }
                if let completed {
                    continuation.resume(returning: completed)
                } else {
                    start { [self] in finish($0) }
                }
            }
        } onCancel: {
            self.finish(fallback)
        }
    }

    private func finish(_ value: Value) {
        let continuation = state.withLock { state -> CheckedContinuation<Value, Never>? in
            switch state {
            case .finished: return nil
            case .preparing:
                state = .finished(value)
                return nil
            case .waiting(let continuation):
                state = .finished(value)
                return continuation
            }
        }
        continuation?.resume(returning: value)
    }
}

/// The companion's line to its installer (Contents/XPCServices). The
/// connection checks the service's signature too.
@MainActor
final class InstallerClient {
    static let shared = InstallerClient()
    private var connection: NSXPCConnection?
    private var connectionID = UUID()

    // Pollers share a deadline and a connection dedicated to this request.
    // Ending the request leaves the connection for installer changes alone.
    private struct EnableQuery {
        let id: UUID
        let connection: NSXPCConnection
        let deadline: Task<Void, Never>
        var waiters: [UUID: @Sendable (Bool) -> Void]
    }

    private var enableQuery: EnableQuery?

    private func proxy(_ failed: @escaping @Sendable () -> Void) -> (any InstallerProtocol)? {
        let connection = self.connection ?? connect()
        return connection.remoteObjectProxyWithErrorHandler { _ in failed() } as? any InstallerProtocol
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: Identity.installer)
        connection.remoteObjectInterface = NSXPCInterface(with: InstallerProtocol.self)
        connection.setCodeSigningRequirement(
            "anchor apple generic and certificate leaf[subject.OU] = \"\(Identity.team)\" and identifier \"\(Identity.installer)\"")
        return connection
    }

    private func connect() -> NSXPCConnection {
        let id = UUID()
        let connection = makeConnection()
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.connectionID == id else { return }
                self.connection = nil
            }
        }
        connection.resume()
        connectionID = id
        self.connection = connection
        return connection
    }

    private func query<T: Sendable>(_ fallback: T, timeout: Duration?,
                                   _ body: (any InstallerProtocol, @escaping @Sendable (T) -> Void) -> Void) async -> T {
        await InstallerWait<T>().wait(for: timeout, returning: fallback) { reply in
            guard !Task.isCancelled, let proxy = proxy({ reply(fallback) }) else {
                reply(fallback)
                return
            }
            body(proxy, reply)
        }
    }

    func facts() async -> SetupFacts? {
        let data: Data? = await query(nil, timeout: .seconds(10)) { proxy, done in proxy.facts { done($0) } }
        return data.flatMap { try? JSONDecoder().decode(SetupFacts.self, from: $0) }
    }

    func isEnabled() async -> Bool {
        let waiterID = UUID()
        defer {
            if enableQuery?.waiters.removeValue(forKey: waiterID) != nil,
               let query = enableQuery, query.waiters.isEmpty {
                finishEnableQuery(query.id, enabled: false)
            }
        }
        return await InstallerWait<Bool>().wait(for: nil, returning: false) { reply in
            guard !Task.isCancelled else { return }
            if enableQuery != nil {
                enableQuery?.waiters[waiterID] = reply
                return
            }
            let id = UUID()
            let connection = makeConnection()
            let deadline = Task { [weak self] in
                do {
                    try await Task.sleep(for: .seconds(2))
                    self?.finishEnableQuery(id, enabled: false)
                } catch {
                    return
                }
            }
            enableQuery = EnableQuery(id: id, connection: connection, deadline: deadline, waiters: [waiterID: reply])
            let finish: @Sendable (Bool) -> Void = { [weak self] enabled in
                Task { @MainActor in self?.finishEnableQuery(id, enabled: enabled) }
            }
            connection.resume()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in finish(false) }) as? any InstallerProtocol
            else { return finishEnableQuery(id, enabled: false) }
            proxy.isEnabled { finish($0) }
        }
    }

    private func finishEnableQuery(_ id: UUID, enabled: Bool) {
        guard let query = enableQuery, query.id == id else { return }
        enableQuery = nil
        query.deadline.cancel()
        query.connection.invalidate()
        for reply in query.waiters.values { reply(enabled) }
    }

    func preflight() async -> Preflight? {
        let data: Data? = await query(nil, timeout: .seconds(65)) { proxy, done in proxy.preflight { done($0) } }
        return data.flatMap { try? JSONDecoder().decode(Preflight.self, from: $0) }
    }

    func exportUserData() async -> Transfer? {
        let data: Data? = await query(nil, timeout: .seconds(65)) { proxy, done in proxy.exportUserData { done($0) } }
        return data.flatMap { try? JSONDecoder().decode(Transfer.self, from: $0) }
    }

    // MARK: Installer changes

    private enum Mutation: Hashable {
        case installIME, enableIME, copyApp, update, importData, uninstall
    }

    private struct Change {
        let id = UUID()
        var reply: (@Sendable (Outcome) -> Void)?
        var outcome: Outcome?
    }

    private var changes: [Mutation: Change] = [:]

    /// The installer owns a change once sent. Keep it even if its caller
    /// leaves, and check the original request before retrying that operation.
    private func mutate(_ kind: Mutation,
                        _ send: (any InstallerProtocol, String, @escaping @Sendable (Outcome) -> Void) -> Void) async -> Outcome {
        guard !Task.isCancelled else { return .cancelled }
        if let pending = changes[kind] { return await reconcile(kind, pending) }

        let request = Change()
        let outcome = await InstallerWait<Outcome>().wait(for: nil, returning: .waiting) { reply in
            guard !Task.isCancelled else { return reply(.cancelled) }
            let finished: @Sendable (Outcome?) -> Void = { result in
                Task { @MainActor in
                    guard var current = self.changes[kind], current.id == request.id, current.outcome == nil else { return }
                    current.outcome = result
                    self.changes[kind] = current
                    current.reply?(result ?? .waiting)
                }
            }
            guard let proxy = proxy({ finished(nil) }) else { return reply(.unreachable) }
            changes[kind] = request
            changes[kind]?.reply = reply
            send(proxy, request.id.uuidString) { finished($0) }
        }
        // A retry must be free to reconcile while the original request runs.
        if changes[kind]?.id == request.id {
            changes[kind]?.reply = nil
            if outcome != .waiting { changes[kind] = nil }
            return outcome
        }
        return outcome == .waiting && Task.isCancelled ? .cancelled : outcome
    }

    private func reconcile(_ kind: Mutation, _ pending: Change) async -> Outcome {
        guard pending.reply == nil else { return .waiting }
        // A reply can arrive while the status query is suspended. Check the
        // request ID again so concurrent callers cannot consume it twice.
        let status: MutationStatus?
        if pending.outcome == nil {
            let data: Data? = await query(nil, timeout: .seconds(3)) {
                proxy, done in proxy.mutationStatus(pending.id.uuidString) { done($0) }
            }
            status = data.flatMap { try? JSONDecoder().decode(MutationStatus.self, from: $0) }
        } else {
            status = nil
        }
        guard !Task.isCancelled, let current = changes[kind], current.id == pending.id else { return .waiting }
        if let outcome = current.outcome {
            changes[kind] = nil
            return outcome
        }
        switch status {
        case .finished(let ok, let message):
            changes[kind] = nil
            return Outcome(ok, message)
        case .unknown: return .unknown
        case .running, nil: return .waiting
        }
    }

    func installIME() async -> (Bool, String) {
        let result = await mutate(.installIME) { proxy, id, done in proxy.installIME(id) { done(Outcome($0, $1)) } }
        return (result.ok, result.message)
    }

    func enableIME() async -> Outcome {
        await mutate(.enableIME) { proxy, id, done in proxy.enableIME(id) { done(Outcome($0, "")) } }
    }

    func selectIME() async -> Bool {
        await query(false, timeout: nil) { proxy, done in proxy.selectIME { done($0) } }
    }

    func launchIME() async -> Bool {
        await query(false, timeout: nil) { proxy, done in proxy.launchIME { done($0) } }
    }

    func importUserData(_ transfer: Transfer) async -> (Bool, String) {
        guard let data = try? JSONEncoder().encode(transfer) else { return (false, "Could not prepare the data.") }
        let result = await mutate(.importData) { proxy, id, done in
            proxy.importUserData(data, request: id) { done(Outcome($0, $1)) }
        }
        return (result.ok, result.message)
    }

    func copyToApplications() async -> (Bool, String) {
        let result = await mutate(.copyApp) { proxy, id, done in proxy.copyToApplications(id) { done(Outcome($0, $1)) } }
        return (result.ok, result.message)
    }

    func pendingUpdate() async -> Outcome? {
        guard let pending = changes[.update] else { return nil }
        return await reconcile(.update, pending)
    }

    func installUpdate(manifest: Data, file: FileHandle) async -> (Bool, String) {
        let result = await mutate(.update) { proxy, id, done in
            proxy.installUpdate(manifest: manifest, file: file, request: id) { done(Outcome($0, $1)) }
        }
        return (result.ok, result.message)
    }

    func pendingUninstall() async -> Outcome? {
        guard let pending = changes[.uninstall] else { return nil }
        return await reconcile(.uninstall, pending)
    }

    func uninstall(wipe: Bool) async -> (Bool, String) {
        let result = await mutate(.uninstall) { proxy, id, done in
            proxy.uninstall(wipe: wipe, request: id) { done(Outcome($0, $1)) }
        }
        return (result.ok, result.message)
    }
}

/// A reply of the installer's: whether it worked, and what to tell the user.
struct Outcome: Equatable, Sendable {
    let ok: Bool
    let message: String
    init(_ ok: Bool, _ message: String) {
        self.ok = ok
        self.message = message
    }
    static let unreachable = Outcome(false, "OctoDot's installer did not answer.")
    static let cancelled = Outcome(false, "安装请求已取消。")
    static let waiting = Outcome(false, "已停止等待安装程序的答复。操作可能仍在进行，请稍后再次检查结果。")
    static let unknown = Outcome(false, "安装程序无法确认上一次操作的结果。请重新打开 OctoDot 检查当前状态。")
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
