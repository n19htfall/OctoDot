import CryptoKit
import Foundation

/// A release, as appcast.json describes it (docs/distribution-and-onboarding.md,
/// section 5). Signed with the project's Ed25519 key over `canonical`: every
/// field but the signature, in a fixed order and form, so the bytes signed
/// and the bytes checked are the same whatever wrote the JSON.
struct UpdateManifest: Codable, Equatable, Sendable {
    var version: String
    var build: Int
    var minimumSystemVersion: String
    var url: String
    var sha256: String
    var size: Int
    var notes: String
    var signature: String

    /// The bytes the signature covers.
    var canonical: Data {
        let notes64 = Data(notes.utf8).base64EncodedString()
        let text = "octodot-update-1\nversion=\(version)\nbuild=\(build)\nminimumSystemVersion=\(minimumSystemVersion)\n" +
            "url=\(url)\nsha256=\(sha256)\nsize=\(size)\nnotes=\(notes64)\n"
        return Data(text.utf8)
    }

    func signed(with key: Curve25519.Signing.PrivateKey) throws -> UpdateManifest {
        var copy = self
        copy.signature = try key.signature(for: canonical).base64EncodedString()
        return copy
    }
}

enum UpdateError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case badSignature
    case notNewer(offered: Int, running: Int)
    case systemTooOld(String)
    case sizeMismatch
    case hashMismatch

    var description: String {
        switch self {
        case .malformed(let why): "the update's description is malformed: \(why)"
        case .badSignature: "the update is not signed with OctoDot's key"
        case .notNewer(let offered, let running): "the offered build \(offered) is not newer than this one (\(running))"
        case .systemTooOld(let needed): "this update needs macOS \(needed) or later"
        case .sizeMismatch: "the download is not the size the update says"
        case .hashMismatch: "the download is not the file the update says (SHA-256)"
        }
    }
}

/// Checks a release before anything of it is used: the signature against the
/// key built into the app, that it is newer than what runs (so an old,
/// validly signed manifest cannot be replayed to downgrade), that this macOS
/// is new enough, that it comes from the project's releases, and later that
/// the download is the one it names.
struct UpdateVerifier: Sendable {
    let publicKey: Curve25519.Signing.PublicKey
    /// Where releases come from: the download URL must start with this.
    let releasesPrefix: String

    init(publicKeyBase64: String, releasesPrefix: String) throws {
        guard let raw = Data(base64Encoded: publicKeyBase64),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else {
            throw UpdateError.malformed("the public key built into the app")
        }
        publicKey = key
        self.releasesPrefix = releasesPrefix
    }

    init(publicKey: Curve25519.Signing.PublicKey, releasesPrefix: String) {
        self.publicKey = publicKey
        self.releasesPrefix = releasesPrefix
    }

    func verify(_ json: Data, runningBuild: Int,
                system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) throws -> UpdateManifest {
        guard json.count < 64 * 1024 else { throw UpdateError.malformed("too large") }
        let manifest: UpdateManifest
        do { manifest = try JSONDecoder().decode(UpdateManifest.self, from: json) } catch {
            throw UpdateError.malformed("not the expected JSON")
        }
        guard let signature = Data(base64Encoded: manifest.signature), signature.count == 64,
              publicKey.isValidSignature(signature, for: manifest.canonical) else { throw UpdateError.badSignature }
        guard manifest.sha256.count == 64, manifest.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw UpdateError.malformed("sha256")
        }
        guard manifest.size > 0, manifest.size < 4_000_000_000 else { throw UpdateError.malformed("size") }
        guard manifest.url.hasPrefix(releasesPrefix), !manifest.url.contains(".."), URL(string: manifest.url) != nil else {
            throw UpdateError.malformed("the download is not from OctoDot's releases")
        }
        guard manifest.build > runningBuild else {
            throw UpdateError.notNewer(offered: manifest.build, running: runningBuild)
        }
        guard let needed = Self.version(manifest.minimumSystemVersion) else {
            throw UpdateError.malformed("minimumSystemVersion")
        }
        if (system.majorVersion, system.minorVersion, system.patchVersion) <
            (needed.majorVersion, needed.minorVersion, needed.patchVersion) {
            throw UpdateError.systemTooOld(manifest.minimumSystemVersion)
        }
        return manifest
    }

    /// The downloaded file is the one the manifest names.
    func verifyPayload(at file: URL, for manifest: UpdateManifest) throws {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw UpdateError.sizeMismatch }
        defer { try? handle.close() }
        try verifyPayload(handle, for: manifest)
    }

    func verifyPayload(_ handle: FileHandle, for manifest: UpdateManifest) throws {
        try handle.seek(toOffset: 0)
        var hasher = SHA256()
        var total = 0
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            total += chunk.count
            guard total <= manifest.size else { throw UpdateError.sizeMismatch }
            hasher.update(data: chunk)
        }
        guard total == manifest.size else { throw UpdateError.sizeMismatch }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == manifest.sha256 else { throw UpdateError.hashMismatch }
    }

    static func version(_ text: String) -> OperatingSystemVersion? {
        let parts = text.split(separator: ".").map { Int($0) }
        guard (1...3).contains(parts.count), parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        let p = parts.map { $0! } + [0, 0]
        return OperatingSystemVersion(majorVersion: p[0], minorVersion: p[1], patchVersion: p[2])
    }
}
