import Foundation

/// The Swift side of the Goose engine's C ABI (build/gen/engine.h).
///
/// Goose requires every exported call to come from the thread that ran
/// `goose_init`. `@MainActor` turns that runtime rule into a compile-time
/// one: IMK delivers events on the main thread, and code off the main actor
/// cannot reach the engine at all. A GCD serial queue would not be enough,
/// because it serializes work but may run it on different threads.
@MainActor
final class Engine {
    static let shared = Engine()

    /// The ABI this host was written against. The engine reports its own.
    static let abiVersion: UInt32 = 1

    struct Session: Hashable, Sendable {
        fileprivate let handle: UInt64
    }

    struct KeyResult: OptionSet, Sendable {
        let rawValue: UInt32
        static let handled = KeyResult(rawValue: 1)
        static let dirty = KeyResult(rawValue: 2)
        static let hasCommit = KeyResult(rawValue: 4)
    }

    /// `KeyEvent.key` values (engine.goose). `.other` means the codepoint
    /// alone describes the key.
    enum Key: UInt16, Sendable {
        case other = 0, backspace, escape, enter, space
    }

    struct Modifiers: OptionSet, Sendable {
        let rawValue: UInt32
        static let shift = Modifiers(rawValue: 1)
        static let control = Modifiers(rawValue: 2)
        static let option = Modifiers(rawValue: 4)
        static let command = Modifiers(rawValue: 8)
    }

    private(set) var isStarted = false

    private init() {}

    /// Starts the Goose runtime on the main thread. Calling it again does nothing.
    func start() {
        guard !isStarted else { return }
        goose_init(CommandLine.argc, CommandLine.unsafeArgv)
        let abi = octo_abi_version()
        precondition(abi == Self.abiVersion, "engine ABI \(abi), host expects \(Self.abiVersion)")
        isStarted = true
    }

    func newSession(clientBundleID: String) -> Session {
        var id = clientBundleID
        let handle = id.withUTF8 { utf8 in
            octo_session_new(sl_u8(data: UnsafeMutablePointer(mutating: utf8.baseAddress),
                                   len: Int64(utf8.count)))
        }
        return Session(handle: handle)
    }

    func free(_ session: Session) { octo_session_free(session.handle) }

    func reset(_ session: Session) { octo_reset(session.handle) }

    func key(_ session: Session, key: Key, codepoint: UInt32, modifiers: Modifiers) -> KeyResult {
        let event = KeyEvent_g(key_g: key.rawValue, flags_g: 0, modifiers_g: modifiers.rawValue,
                               codepoint_g: codepoint, time_ms_g: 0)
        return KeyResult(rawValue: octo_key(session.handle, event))
    }

    /// The engine lends the snapshot bytes only until the next call into it,
    /// so they are decoded (copied) here, before anything else can run.
    func snapshot(_ session: Session) -> Snapshot {
        var length: Int64 = 0
        guard let bytes = octo_snapshot(session.handle, &length), length > 0 else { return .empty }
        return Snapshot(bytes: UnsafeRawBufferPointer(start: bytes, count: Int(length))) ?? .empty
    }

    /// One key, and the snapshot only when the key changed something.
    func process(_ session: Session, _ key: TranslatedKey) -> (KeyResult, Snapshot?) {
        let result = self.key(session, key: key.key, codepoint: key.codepoint, modifiers: key.modifiers)
        let changed = result.contains(.dirty) || result.contains(.hasCommit)
        return (result, changed ? snapshot(session) : nil)
    }
}

/// A key as the engine sees it, made from an NSEvent by the IME (or by a test).
struct TranslatedKey: Sendable {
    var key: Engine.Key
    var codepoint: UInt32
    var modifiers: Engine.Modifiers
}
