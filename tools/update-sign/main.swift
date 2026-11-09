// Signs OctoDot's update manifests (docs/distribution-and-onboarding.md,
// section 5), with the very UpdateManifest the app verifies with (compiled in
// from macos/Sources/Setup), so the signed bytes and the checked bytes are
// the same by construction.
//
//   octo-update-sign keygen
//       a new Ed25519 pair: "private <base64>" and "public <base64>" lines
//   octo-update-sign sign --version V --build N --min 14.0 --url URL --file ZIP [--notes TEXT] < private key
//       appcast.json on standard output: the file's size and SHA-256, signed
//       with the private key read (base64) from standard input
//   octo-update-sign verify --public KEY --running N < appcast.json
//       checks a manifest as the app would
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("octo-update-sign: \(message)\n".utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let args = CommandLine.arguments
guard args.count >= 2 else { fail("usage: octo-update-sign keygen | sign … | verify …") }

switch args[1] {
case "keygen":
    let key = Curve25519.Signing.PrivateKey()
    print("private \(key.rawRepresentation.base64EncodedString())")
    print("public \(key.publicKey.rawRepresentation.base64EncodedString())")
case "sign":
    let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let raw = Data(base64Encoded: input), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        fail("no private key (base64) on standard input")
    }
    guard let version = option("--version"), let build = option("--build").flatMap(Int.init),
          let minimum = option("--min"), let url = option("--url"), let path = option("--file"),
          let data = FileManager.default.contents(atPath: path) else {
        fail("sign needs --version, --build, --min, --url and a readable --file")
    }
    let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let manifest = UpdateManifest(version: version, build: build, minimumSystemVersion: minimum, url: url,
                                  sha256: digest, size: data.count, notes: option("--notes") ?? "", signature: "")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let signed = try? manifest.signed(with: key), let json = try? encoder.encode(signed) else { fail("signing failed") }
    print(String(decoding: json, as: UTF8.self))
case "verify":
    guard let publicKey = option("--public"), let running = option("--running").flatMap(Int.init),
          let verifier = try? UpdateVerifier(publicKeyBase64: publicKey,
                                             releasesPrefix: option("--prefix") ?? "https://github.com/") else {
        fail("verify needs --public KEY and --running BUILD")
    }
    do {
        let manifest = try verifier.verify(FileHandle.standardInput.readDataToEndOfFile(), runningBuild: running)
        print("valid: OctoDot \(manifest.version) (\(manifest.build)), \(manifest.size) bytes, \(manifest.url)")
    } catch {
        fail("\(error)")
    }
default:
    fail("unknown command \(args[1])")
}
