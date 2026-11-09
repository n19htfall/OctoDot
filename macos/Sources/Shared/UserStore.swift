import CryptoKit
import Foundation
import Security

/// Where the user dictionary's key lives. The IME uses the Keychain; tests
/// use a key in memory.
protocol UserKeyProvider {
    /// The key, created on first use; nil if there is none and none can be made.
    func key() -> SymmetricKey?
}

/// A 256-bit key in the login Keychain, readable only by this app (by its
/// code signature), never synced, and only after the first unlock.
struct KeychainKeyProvider: UserKeyProvider {
    var service: String
    var account = "user-dictionary-key-1"

    func key() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data,
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        let fresh = SymmetricKey(size: .bits256)
        let data = fresh.withUnsafeBytes { Data($0) }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrLabel as String: "OctoDot user dictionary key",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: data,
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess ? fresh : nil
    }

    /// Removes the key (for tests of the Keychain itself).
    func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

struct MemoryKeyProvider: UserKeyProvider {
    var stored = SymmetricKey(size: .bits256)
    func key() -> SymmetricKey? { stored }
}

/// The user dictionary at rest. The engine hands over its text form; this
/// seals it with AES-GCM under the key and writes it atomically, keeping the
/// previous generation beside it:
///
///   user-dictionary          "ODU1" + AES.GCM sealed box (nonce, ciphertext, tag)
///   user-dictionary.previous the one before
///
/// Reading falls back from the current file to the previous one, and from
/// both to empty: a wrong key, a damaged file or a missing one never stops
/// typing. A file that cannot be read is moved aside (".unreadable") rather
/// than overwritten, in case the key comes back.
struct UserStore {
    static let magic = Data("ODU1".utf8)
    /// Bound into every seal, so no other sealed blob can be swapped in.
    static let context = Data("OctoDot user dictionary".utf8)

    var directory: URL
    var keys: any UserKeyProvider

    var current: URL { directory.appendingPathComponent("user-dictionary") }
    var previous: URL { directory.appendingPathComponent("user-dictionary.previous") }

    enum LoadResult: Equatable {
        case loaded(Data)       // from the current file
        case recovered(Data)    // the current file failed; the previous one opened
        case empty              // nothing stored yet
        case unreadable         // files exist, none opens (moved aside)
    }

    func seal(_ plain: Data, with key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, authenticating: Self.context)
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        return Self.magic + combined
    }

    func open(_ sealed: Data, with key: SymmetricKey) -> Data? {
        guard sealed.count > Self.magic.count, sealed.prefix(Self.magic.count) == Self.magic,
              let box = try? AES.GCM.SealedBox(combined: sealed.dropFirst(Self.magic.count)) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: Self.context)
    }

    func load() -> LoadResult {
        let fm = FileManager.default
        let haveCurrent = fm.fileExists(atPath: current.path)
        let havePrevious = fm.fileExists(atPath: previous.path)
        guard haveCurrent || havePrevious else { return .empty }
        guard let key = keys.key() else { return .unreadable }
        if haveCurrent, let sealed = try? Data(contentsOf: current), let plain = open(sealed, with: key) {
            return .loaded(plain)
        }
        if havePrevious, let sealed = try? Data(contentsOf: previous), let plain = open(sealed, with: key) {
            if haveCurrent { setAside(current) }
            return .recovered(plain)
        }
        if haveCurrent { setAside(current) }
        if havePrevious { setAside(previous) }
        return .unreadable
    }

    /// Seals `plain` and makes it the current file; the current one becomes
    /// the previous. False if there is no key or the write failed.
    @discardableResult
    func save(_ plain: Data) -> Bool {
        guard let key = keys.key(), let sealed = try? seal(plain, with: key) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let staged = directory.appendingPathComponent("user-dictionary.new")
            try sealed.write(to: staged, options: [.atomic, .completeFileProtection])
            if fm.fileExists(atPath: current.path) {
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                try fm.moveItem(at: current, to: previous)
            }
            try fm.moveItem(at: staged, to: current)
            return true
        } catch {
            return false
        }
    }

    private func setAside(_ file: URL) {
        let aside = file.appendingPathExtension("unreadable")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: file, to: aside)
    }
}
