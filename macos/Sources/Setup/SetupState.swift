import Foundation

/// One input method bundle as the companion compares them: its version and
/// build, and the hashes that say whether its core or its launcher changed
/// (Info.plist's OctoDotCore names the core by its code and data inputs, and
/// Resources/launcher.sha256 holds the launcher's).
struct BundleStamp: Codable, Equatable, Sendable {
    var version: String
    var build: Int
    var core: String
    var launcher: String

    /// The stamp of the bundle at `url`, or nil if it is not one.
    static func of(_ url: URL) -> BundleStamp? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let version = info["CFBundleShortVersionString"] as? String,
              let buildText = info["CFBundleVersion"] as? String, let build = Int(buildText) else { return nil }
        let core = info["OctoDotCore"] as? String ?? ""
        let launcherFile = url.appendingPathComponent("Contents/Resources/launcher.sha256")
        let launcher = (try? String(contentsOf: launcherFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return BundleStamp(version: version, build: build, core: core, launcher: launcher)
    }
}

/// What the installer finds on this Mac: everything the companion's first
/// screen depends on, gathered in one place so the decision is a pure
/// function of it (SetupState.of), tested without touching the system.
struct SetupFacts: Codable, Equatable, Sendable {
    /// Where the companion runs.
    var appPath: String
    var appOnReadOnlyVolume: Bool
    /// The IME inside the companion, and the one in ~/Library/Input Methods.
    var embedded: BundleStamp?
    var installed: BundleStamp?
    /// The install before the move (com.example.inputmethod.OctoDot, as
    /// ~/Library/Input Methods/OctoDot.app): installing removes it.
    var legacyInstalled: Bool
    /// The installed IME's input source is enabled.
    var enabled: Bool
    /// An IME is running, but has not confirmed that it uses the installed core.
    /// Optional so older installer replies can still be decoded.
    var activationPending: Bool? = nil
    /// The core acknowledged by the running IME, when it has answered.
    var runningCore: String? = nil
}

/// A reply names what is actually running. Silence is a failure only while
/// an IME process still exists; a stopped IME will load the installed core
/// on its next launch.
enum CoreActivation: Equatable {
    case active
    case notRunning
    case unconfirmed(String?)

    static func classify(expected: String, answer: String?, running: Bool) -> CoreActivation {
        guard running else { return .notRunning }
        if answer == expected { return .active }
        return .unconfirmed(answer == "none" ? nil : answer)
    }
}

/// What the companion does about it.
enum SetupState: Equatable, Sendable {
    /// Running from the disk image, or from where Gatekeeper translocated it:
    /// move to Applications first.
    case wrongLocation
    /// No input method installed.
    case notInstalled
    /// The installed IME is older than the one inside the companion, or its
    /// core differs; `restart` if its launcher differs too.
    case outdated(restart: Bool)
    /// Installed and current, but not among the input sources.
    case disabled
    /// Installed, current and enabled: show the companion home screen.
    case ready

    static func of(_ facts: SetupFacts) -> SetupState {
        let path = facts.appPath
        if facts.appOnReadOnlyVolume || path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") {
            return .wrongLocation
        }
        guard let installed = facts.installed else { return .notInstalled }
        // The old install still beside a current one: installing again
        // removes it.
        if facts.legacyInstalled { return .outdated(restart: false) }
        if let embedded = facts.embedded {
            let older = installed.build < embedded.build
            let sameBuild = installed.build == embedded.build
            let launcherDiffers = installed.launcher != embedded.launcher
            if older || (sameBuild && (installed.core != embedded.core || launcherDiffers)) {
                return .outdated(restart: launcherDiffers)
            }
        }
        if facts.activationPending == true && facts.embedded == installed { return .outdated(restart: false) }
        return facts.enabled ? .ready : .disabled
    }
}
