import CommonCrypto
import CryptoKit
import Foundation

/// A backup of the user's data (a Transfer) as a file: sealed with AES-GCM
/// under a key made from a passphrase the user gives (PBKDF2-SHA256, 600,000
/// rounds, a fresh salt each time), so the file is safe wherever it goes.
///
///   "ODB1" | salt (16) | rounds (u32, big-endian) | AES.GCM combined box
enum Backup {
    static let magic = Data("ODB1".utf8)
    static let rounds: UInt32 = 600_000
    static let fileExtension = "octodot-backup"

    static func seal(_ transfer: Transfer, passphrase: String) throws -> Data {
        var salt = Data(count: 16)
        guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess
        else { throw CocoaError(.coderInvalidValue) }
        let key = try derive(passphrase, salt: salt, rounds: rounds)
        let box = try AES.GCM.seal(try JSONEncoder().encode(transfer), using: key, authenticating: magic)
        guard let combined = box.combined else { throw CocoaError(.coderInvalidValue) }
        var count = rounds.bigEndian
        return magic + salt + Data(bytes: &count, count: 4) + combined
    }

    /// The transfer, or nil for a wrong passphrase or a damaged file.
    static func open(_ data: Data, passphrase: String) -> Transfer? {
        guard data.count > 24 + 28, data.prefix(4) == magic else { return nil }
        let salt = data.subdata(in: 4..<20)
        let rounds = data.subdata(in: 20..<24).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        guard rounds >= 100_000, rounds <= 10_000_000, let key = try? derive(passphrase, salt: salt, rounds: rounds),
              let box = try? AES.GCM.SealedBox(combined: data.subdata(in: 24..<data.count)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: magic) else { return nil }
        return try? JSONDecoder().decode(Transfer.self, from: plain)
    }

    private static func derive(_ passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        var key = Data(count: 32)
        let password = Array(passphrase.utf8)
        let status = key.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password.map { Int8(bitPattern: $0) }, password.count,
                                     s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds,
                                     out.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return SymmetricKey(data: key)
    }
}
