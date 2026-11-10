import CryptoKit
import Foundation

// The companion's decisions, tested on their own (docs/distribution-and-onboarding.md,
// section 8): the setup state for every situation the companion can find, and
// the update verifier against good and bad manifests. Nothing here touches
// the input sources or the network.

nonisolated(unsafe) var failures = 0
func check(_ ok: Bool, _ what: String) {
    print(ok ? "ok    \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

// MARK: Setup states

let current = BundleStamp(version: "0.2.0", build: 12, core: "OctoDotCore-aaaa.dylib", launcher: "l1")
func facts(installed: BundleStamp?, enabled: Bool = true, legacy: Bool = false,
           path: String = "/Applications/OctoDot.app", readOnly: Bool = false) -> SetupFacts {
    SetupFacts(appPath: path, appOnReadOnlyVolume: readOnly, embedded: current, installed: installed,
               legacyInstalled: legacy, enabled: enabled)
}

check(SetupState.of(facts(installed: nil)) == .notInstalled,
      "fresh install: no IME in ~/Library/Input Methods → install it")
var older = current
older.build = 11
older.core = "OctoDotCore-bbbb.dylib"
check(SetupState.of(facts(installed: older)) == .outdated(restart: false),
      "outdated: an older build with the same launcher → update in place (reload)")
var otherLauncher = older
otherLauncher.launcher = "l0"
check(SetupState.of(facts(installed: otherLauncher)) == .outdated(restart: true),
      "outdated with another launcher → update, restarting the IME")
var rebuilt = current
rebuilt.core = "OctoDotCore-cccc.dylib"
check(SetupState.of(facts(installed: rebuilt)) == .outdated(restart: false),
      "same build, another core (a development rebuild) → update in place")
check(SetupState.of(facts(installed: current, enabled: false)) == .disabled,
      "installed and current, not enabled → the enabling step")
check(SetupState.of(facts(installed: current)) == .ready,
      "installed, enabled and current → skip onboarding, open Settings")
var pendingActivation = facts(installed: current)
pendingActivation.activationPending = true
pendingActivation.runningCore = "OctoDotCore-older.dylib"
check(SetupState.of(pendingActivation) == .outdated(restart: false),
      "matching bundles with an unconfirmed running core → retry activation")
check((try? JSONDecoder().decode(SetupFacts.self, from: JSONEncoder().encode(pendingActivation)))?.runningCore ==
      "OctoDotCore-older.dylib", "setup facts keep the running core distinct from the installed one")
let oldFacts = facts(installed: current)
let oldJSON = try! JSONEncoder().encode(oldFacts)
check((try? JSONDecoder().decode(SetupFacts.self, from: oldJSON)) == oldFacts,
      "setup facts without running-core fields still decode")
pendingActivation.activationPending = false
check(SetupState.of(pendingActivation) == .ready, "a confirmed running core is ready")
check(CoreActivation.classify(expected: "new", answer: "old", running: true) == .unconfirmed("old") &&
      CoreActivation.classify(expected: "new", answer: nil, running: true) == .unconfirmed(nil) &&
      CoreActivation.classify(expected: "new", answer: "none", running: true) == .unconfirmed(nil),
      "an old, missing or failed activation reply is never treated as success")
check(CoreActivation.classify(expected: "new", answer: "new", running: true) == .active &&
      CoreActivation.classify(expected: "new", answer: nil, running: false) == .notRunning &&
      CoreActivation.classify(expected: "new", answer: "new", running: false) == .notRunning,
      "activation distinguishes a confirmed running core from a stopped process")
var newer = current
newer.build = 13
newer.core = "OctoDotCore-dddd.dylib"
check(SetupState.of(facts(installed: newer)) == .ready,
      "an installed IME newer than the companion is never downgraded")
check(SetupState.of(facts(installed: nil, legacy: true)) == .notInstalled,
      "only the old com.example install → install the new one (which removes the old)")
check(SetupState.of(facts(installed: current, legacy: true)) == .outdated(restart: false),
      "the old install still beside a current one → install again, which removes it")
check(SetupState.of(facts(installed: nil, path: "/Volumes/OctoDot/OctoDot.app", readOnly: true)) == .wrongLocation,
      "launched from the disk image → move to Applications first")
check(SetupState.of(facts(installed: current, path: "/private/var/folders/x/AppTranslocation/1/d/OctoDot.app"))
      == .wrongLocation, "launched translocated by Gatekeeper → move to Applications first")
check(SetupState.of(facts(installed: current, path: "/Users/me/Applications/OctoDot.app")) == .ready,
      "~/Applications is a fine place too")

// A stamp read from a bundle on disk.
let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stamp-\(UUID().uuidString)/X.app")
try! FileManager.default.createDirectory(at: dir.appendingPathComponent("Contents/Resources"),
                                         withIntermediateDirectories: true)
(["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "45", "OctoDotCore": "OctoDotCore-ab.dylib"]
    as NSDictionary).write(to: dir.appendingPathComponent("Contents/Info.plist"), atomically: true)
try! "f00d\n".write(to: dir.appendingPathComponent("Contents/Resources/launcher.sha256"), atomically: true, encoding: .utf8)
check(BundleStamp.of(dir) == BundleStamp(version: "1.2.3", build: 45, core: "OctoDotCore-ab.dylib", launcher: "f00d"),
      "a bundle's stamp: version, build, core and launcher, from Info.plist and launcher.sha256")
check(BundleStamp.of(dir.deletingLastPathComponent().appendingPathComponent("none.app")) == nil,
      "no bundle, no stamp")

// MARK: Update verification

let key = Curve25519.Signing.PrivateKey()
let prefix = "https://github.com/n19htfall/OctoDot/releases/download/"
let verifier = UpdateVerifier(publicKey: key.publicKey, releasesPrefix: prefix)
let payload = Data((0..<5000).map { UInt8($0 % 251) })
let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
let unsigned = UpdateManifest(version: "0.2.0", build: 12, minimumSystemVersion: "14.0",
                              url: prefix + "v0.2.0/OctoDot-0.2.0.zip", sha256: digest, size: payload.count,
                              notes: "更快的整句 · faster sentences", signature: "")
let good = try! unsigned.signed(with: key)
func json(_ m: UpdateManifest) -> Data { try! JSONEncoder().encode(m) }
func rejects(_ data: Data, running: Int = 11, _ expected: UpdateError, _ what: String) {
    do {
        _ = try verifier.verify(data, runningBuild: running)
        check(false, what + " (it was accepted)")
    } catch let error as UpdateError {
        check(error == expected, what + " (\(error))")
    } catch {
        check(false, what + " (\(error))")
    }
}

let accepted = try? verifier.verify(json(good), runningBuild: 11)
check(accepted == good, "a manifest signed with the release key, for a newer build, is accepted")
let file = FileManager.default.temporaryDirectory.appendingPathComponent("payload-\(UUID().uuidString)")
try! payload.write(to: file)
check((try? verifier.verifyPayload(at: file, for: good)) != nil, "  and its download, of the size and SHA-256 it names")

var tamperedHash = good
tamperedHash.sha256 = String(digest.reversed())
rejects(json(tamperedHash), .badSignature, "a changed hash breaks the signature")
var tamperedURL = good
tamperedURL.url = prefix + "v0.2.0/evil.zip"
rejects(json(tamperedURL), .badSignature, "a changed URL breaks the signature")
rejects(json(good), running: 12, .notNewer(offered: 12, running: 12), "the build already running is refused")
rejects(json(good), running: 20, .notNewer(offered: 12, running: 20), "a downgrade is refused, validly signed or not")
let stranger = try! unsigned.signed(with: Curve25519.Signing.PrivateKey())
rejects(json(stranger), .badSignature, "a manifest signed with another key is refused")
var garbled = good
garbled.signature = "not base64!"
rejects(json(garbled), .badSignature, "a malformed signature is refused")
var shortSig = good
shortSig.signature = Data(repeating: 1, count: 32).base64EncodedString()
rejects(json(shortSig), .badSignature, "a signature of the wrong length is refused")
rejects(Data("{\"version\": 1}".utf8), .malformed("not the expected JSON"), "something that is not a manifest is refused")
var elsewhere = unsigned
elsewhere.url = "https://example.com/OctoDot.zip"
rejects(json(try! elsewhere.signed(with: key)), .malformed("the download is not from OctoDot's releases"),
        "a signed manifest pointing outside OctoDot's releases is refused")
var future = unsigned
future.minimumSystemVersion = "99.0"
rejects(json(try! future.signed(with: key)), .systemTooOld("99.0"), "an update for a later macOS is refused")

var wrongSize = good
wrongSize.size += 1
check((try? verifier.verifyPayload(at: file, for: wrongSize)) == nil, "a download of another size is refused")
var wrongHash = good
wrongHash.sha256 = String(repeating: "0", count: 64)
do {
    try verifier.verifyPayload(at: file, for: wrongHash)
    check(false, "a download with another SHA-256 is refused")
} catch {
    check(error as? UpdateError == .hashMismatch, "a download with another SHA-256 is refused")
}
try? FileManager.default.removeItem(at: file)

check(UpdateVerifier.version("14.0")?.majorVersion == 14 && UpdateVerifier.version("x.1") == nil,
      "versions parse as numbers or not at all")

// MARK: Transfer

let transfer = Transfer(userDictionary: Data("words".utf8), customPhrases: Data("我\two\n".utf8), preferences: nil)
check((try? JSONDecoder().decode(Transfer.self, from: JSONEncoder().encode(transfer))) == transfer,
      "a transfer survives its trip through JSON")

if failures > 0 { exit(1) }
