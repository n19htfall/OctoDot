# Distribution, onboarding and updates

Status: built, 2026-11-09 (section 10 says what was verified, and what was
not). The owner's decisions (section 0) were taken the same day.

## 0. Summary, and what needs deciding

macOS loads input methods only from `~/Library/Input Methods` or
`/Library/Input Methods`, never from `/Applications`. So OctoDot ships as
two bundles: an ordinary app the user drags to `/Applications`, which
installs, updates and removes the input method it carries inside it.

```
/Applications/OctoDot.app                     companion: onboarding, updates, uninstall
  Contents/MacOS/OctoDot
  Contents/XPCServices/OctoDotInstaller.xpc   file and input-source work the sandboxed app cannot do
  Contents/Resources/OctoDotIME.app           the input method, as shipped
~/Library/Input Methods/OctoDotIME.app        the input method, as installed (a copy of the one above)
```

What does **not** change: the IME process stays sandboxed with no network
entitlement and no third-party code; its updates keep loading the new core
into the running process (no app has to be reopened); the user dictionary
and custom phrases stay where they are, in the IME's own container.

Decisions this plan takes (section by section below), and the open ones:

| | Decided | Not taken |
|---|---|---|
| **A. The companion's privileges** | Sandboxed, as the brief asks, with an embedded **XPC installer** that is not sandboxed, has no network, and only installs bundles signed by team G4JRQAX252 | No sandbox for the companion (Hardened Runtime only): one process, simpler, but the process that talks to the network then has the user's files |
| **B. Where Settings live** | **In the IME, as now**: the companion's Settings opens the IME's window. Settings act on the live engine at once and need its lists (schemes, sets, the reranker); a copy in the companion would need its own engine or a protocol to the IME's | Move Settings to the companion: shared preferences in the App Group, the IME applying them on a notification |
| **C. The IME's bundle ID** | **A real one now**, `io.github.n19htfall.inputmethod.OctoDot`. The old `com.example.inputmethod.OctoDot` install is removed when the new one is installed, and its data is **not** carried over (the owner chose a fresh start, 2026-11-09; a migration was built first, then taken out) | Keep the placeholder; or migrate the old data |
| **D. The updater** | Native: `URLSession` + CryptoKit Ed25519 over a signed `appcast.json` on GitHub Releases. No third-party code, and the install step is the XPC installer's either way | Sparkle 2: its sandboxed mode needs its own XPC services and Mach exceptions; a binary framework to pin, sign and embed |
| **E. The installed name** | `OctoDotIME.app`, as the brief says (decided). With a new bundle ID it is a new input method, not a restart of the old one: apps connect to it afresh | Keep installing as `OctoDot.app`: two apps named OctoDot |
| **F. Signing** | Development builds signed with **Apple Development (team G4JRQAX252)**, not ad hoc: stable designated requirement, App Group allowed, library validation back on. The Keychain key, made by today's ad hoc build, asks once to be used by the new signature: onboarding's pre-flight makes that happen there, not mid-sentence | Stay ad hoc for development: no App Group (macOS refuses group containers to unsigned code) |

## 1. Bundles

### OctoDot.app (`/Applications`)

- `CFBundleIdentifier` `com.example.OctoDot` (the IME's, less `.inputmethod`),
  `CFBundlePackageType` APPL, `LSMinimumSystemVersion` 14.0, a Dock app
  (`LSUIElement` false), `CFBundleURLTypes` → scheme `octodot`
  (`octodot://settings`, `octodot://update`, `octodot://setup`).
- `CFBundleShortVersionString` / `CFBundleVersion`: the product's version
  and build number, one pair for both bundles (section 7).
- `OctoDotUpdatePublicKey`: the Ed25519 public key, base64.
- Entitlements:

  | Key | Why |
  |---|---|
  | `com.apple.security.app-sandbox` | |
  | `com.apple.security.network.client` | update checks and downloads, nothing else |
  | `com.apple.security.application-groups` `[G4JRQAX252.octodot]` | the hand-over folder shared with the IME (pre-flight, export) |
  | `com.apple.security.files.user-selected.read-write` | exporting the user dictionary to where the user chooses |

  No `get-task-allow` in release builds.

### OctoDotInstaller.xpc (inside the companion)

An XPC service (`CFBundlePackageType` XPC!, `XPCService` → `ServiceType`
Application), not sandboxed, Hardened Runtime, **no network**, launched only
by the companion. Its whole interface:

| Call | Does |
|---|---|
| `state()` | the installed IME's version, build, core and launcher hashes; whether it is registered, enabled, running |
| `installIME()` | copies `Resources/OctoDotIME.app` to `~/Library/Input Methods`, atomically (below), registers and enables it; reloads or restarts the running IME |
| `selectIME()` / `enable()` / `disable()` | TIS calls (section 3) |
| `preflight()` | runs the installed IME's `--preflight` (in the IME's own sandbox) and returns its JSON |
| `installUpdate(staged, signature)` | verifies a downloaded update again, swaps `/Applications/OctoDot.app` |
| `uninstall(keepData)` | section 6 |

It accepts a bundle only if `codesign --verify --strict` passes and its
signature's team is G4JRQAX252 with the expected identifier; it checks the
caller is the companion (same team, its identifier) on every connection.

### OctoDotIME.app (`~/Library/Input Methods`)

Today's input method, renamed: executable `OctoDotIME`, everything else as
now (launcher + `Contents/Frameworks/OctoDotCore-<hash>.dylib` + data),
except the grammar model: the bundle pins it (`data/grammar.pin`) and reads
it from the App Group folder (section 5).
`LSUIElement` true, `InputMethodConnectionName`, `ComponentInputModeDict`
unchanged. Entitlements:

| Key | Why |
|---|---|
| `com.apple.security.app-sandbox` | |
| `com.apple.security.temporary-exception.mach-register.global-name` `<id>_Connection` | IMKServer |
| `com.apple.security.application-groups` `[G4JRQAX252.octodot]` | the hand-over folder |

Gone: `com.apple.security.cs.disable-library-validation`, needed only
because ad hoc signatures have no team; with a team signature the cores it
loads pass library validation. Never: `network.client`/`network.server`,
`get-task-allow`, file exceptions.

The input menu gets "Check for Updates…", which opens `octodot://update`
(opening a URL is allowed in the sandbox; the companion does the rest).

## 2. Identity and data

- **Containers.** The user dictionary (`user-dictionary`, sealed with
  AES-GCM), custom phrases and their compiled images stay in the IME's
  container. Only the IME reads them. Updates never touch them.
- **App Group** `G4JRQAX252.octodot`: macOS form (team prefix), which needs
  no provisioning profile; macOS 15 and later refuse `group.`-style names
  without one. Holds hand-over files (the pre-flight result, an export the
  user asked for) and the grammar model the IME pins, in
  `Grammar/<sha256>/` (section 5).
- **Keychain.** The key stays a login-Keychain item of the IME, readable by
  its signature. The pre-flight (the IME binary itself, in its sandbox)
  reads or creates it during onboarding, so any confirmation macOS asks for
  comes then.
- **Identifiers.** IME `io.github.n19htfall.inputmethod.OctoDot`, companion
  `io.github.n19htfall.OctoDot`, installer
  `io.github.n19htfall.OctoDot.Installer`, App Group
  `G4JRQAX252.io.github.n19htfall.octodot`.
- **The old install** (`com.example.inputmethod.OctoDot`, ad hoc signed, at
  `~/Library/Input Methods/OctoDot.app`) is removed by installing the new
  one, once the new one is in place: its input source is turned off, its
  process quits, its bundle is deleted, and, if it was among the input
  sources, the new one takes its place. Its learned words stay in its
  container (`~/Library/Containers/com.example.inputmethod.OctoDot`),
  sealed under its key in the Keychain, neither read nor carried over: the
  new install starts afresh.

## 3. First run

The companion decides what to show from one value, `SetupState`, computed by
a pure function (tested on its own, section 8):

| State | When | Shows |
|---|---|---|
| `wrongLocation` | the app runs from a read-only volume or outside `/Applications` | "Move to Applications" (copy, relaunch from there, eject) |
| `notInstalled` | no `~/Library/Input Methods/OctoDotIME.app` (perhaps the old `OctoDot.app`, which installing removes) | the wizard from step B |
| `outdated` | the installed build is older, its core differs, its running core has not confirmed activation, or the old `OctoDot.app` is still beside it | an update or activation retry (section 4), then on |
| `disabled` | installed and current, not enabled in TIS | the wizard at step B's enabling |
| `ready` | installed, current, enabled | The companion home screen with a button to open the IME's Settings |

The wizard, one SwiftUI window in the system's design:

- **A. Location.** Detected by `URL.resourceValues(.volumeIsReadOnlyKey)` and
  the path; the copy goes through the installer, then the app relaunches
  from `/Applications`.
- **B. Install and enable.** `installIME()`: copy, register
  (`TISRegisterInputSource`), find the bundle's sources
  (`TISCreateInputSourceList` filtered by `kTISPropertyBundleID`), enable
  the bundle and its mode (`TISEnableInputSource`). Then poll
  `kTISPropertyInputSourceIsEnabled` every 0.5 s; if macOS wants the user to
  confirm, "Open Keyboard Settings…"
  (`x-apple.systempreferences:com.apple.Keyboard-Settings.extension`) with a
  picture of the switch, and the step completes by itself when it turns on.
  (OctoDot has one input mode; 全拼 and 小鹤双拼 are its schemes, chosen in
  Settings or step D, not separate sources.)
- **C. Privacy and pre-flight.** What the IME never asks for (Accessibility,
  Input Monitoring, the clipboard, the network), and `preflight()`: the
  container is writable, the App Group is reachable, the Keychain key reads
  back.
- **D. Try it.** A text field; on focus, `selectIME()`
  (`TISSelectInputSource`), so typing `nihao` (or `wussqigr` in 小鹤双拼)
  shows the candidate window right there. Scheme and character set
  pickers beside it write the IME's settings (posted to the IME, which owns
  them).

## 4. Keeping the IME in step with the companion

On every launch, and after an update of itself, the companion compares its
embedded IME with the installed one: `CFBundleVersion`, and the hashes of
the core and the launcher (the `launcher.sha256` OctoDot already writes).

- **Same**: if the IME is running, ask it to confirm the installed core;
  a missing or different answer makes setup retry activation.
- **Newer core, same launcher** (nearly every update): the new bundle is
  staged beside the installed one and the two are swapped in one
  `renamex_np(RENAME_SWAP)`, so the path never holds half a bundle; then the
  running IME is told to reload (`<id>.reload`, as `make install` does).
  The process, and every app's connection to it, stays.
- **New launcher** (rare): the same swap,
  then the IME process is asked to quit (`SIGTERM`, which already saves the
  user dictionary and hands the journal over), and macOS starts the new
  one when it is next needed. The companion says that Chromium-based apps
  may need reopening.
- A composition in progress is never cut: the launcher keeps the old core
  and retries until no composition or phrase compilation is in progress.
  It reports the core actually running, not the one merely requested. The
  core filename hashes its data images and grammar pin as well as its code.
- Each active generation has a temporary copy of its data. Since only one
  engine runtime may run at a time, the launcher stops the previous core
  before starting the new one. If startup fails, it starts the previous core
  again against its retained data, reports the failure, and retries with
  increasing delays. A failed data copy leaves the running core alone. The
  prior copy is removed only after the new core starts successfully; old
  Swift libraries remain mapped in the process. A periodic comparison also
  retries a generation if the reload notification itself was missed.

The user dictionary and phrases are in the container, untouched by the swap;
compiled phrase images older than the new core are recompiled at its first
launch (Phrases.start already compares their dates with the core's).

## 5. Software updates

- **Manifest** (`appcast.json`, attached to each GitHub Release, the latest
  one fetched from `https://github.com/n19htfall/OctoDot/releases/latest/download/appcast.json`):

  ```json
  {"version": "0.2.0", "build": 12, "minimumSystemVersion": "14.0",
   "url": "https://github.com/n19htfall/OctoDot/releases/download/v0.2.0/OctoDot-0.2.0.zip",
   "sha256": "…", "size": 123456789, "notes": "…",
   "signature": "<base64 Ed25519 over the canonical bytes of every other field>"}
  ```

- **Verification**, all of it before anything is installed: the signature
  against the embedded public key; `build` greater than the running one
  (no downgrades, no replays of an old manifest); `minimumSystemVersion`;
  the download's size and SHA-256 against the manifest; then the unpacked
  app's code signature (team, identifier, notarization ticket) in the
  installer. Any failure discards the download.
- **Keys.** `tools/release-key.sh` makes the Ed25519 pair once: the private
  key in the login Keychain (never in the repository), the public key into
  `Info.plist`. `tools/sign-manifest` signs a release's manifest.
- **When.** "Check for Updates…" in the companion (and from the IME's input
  menu, by URL); a background check at most once a day while the companion
  runs, off unless the user turns it on.
- **Applying.** The installer swaps `/Applications/OctoDot.app`, the
  companion relaunches, and section 4 brings the IME along.
- **The grammar model stays out of updates.** It is 400 MB of a 488 MB app
  and changes only with `data/grammar.lock`, so it lives outside the
  bundles, in the App Group folder at `Grammar/<sha256>/<name>.gram`, which
  the IME maps (`Sources/Setup/GrammarPin.swift`). The disk image's
  companion carries a copy (`Contents/Resources/Grammar/`); the update's
  (`build/update/OctoDot.app`, the zip) is the same bundles without it,
  the companion signed again around them: a 41 MiB download instead of
  394. Before it installs an IME, the companion makes sure the folder holds
  the model that IME pins (`GrammarStore`): from its own copy, or else
  downloaded from the model's own release, `grammar-<sha256 prefix>`
  (`make grammar-release`, once per lock). Either way the file must have
  the SHA-256 the IME's signed bundle pins, and goes in through a staging
  folder renamed into place. Models one folder each, so a new one arrives
  beside the one in use; after the install the others are removed. Without
  the model the IME types as it does with the model turned off, and the
  companion tries again when it is next opened.

## 6. Uninstall

"Uninstall OctoDot…" (Settings → Advanced, and the Help menu): disable the
sources (`TISDisableInputSource`), quit the IME, remove
`~/Library/Input Methods/OctoDotIME.app`; optionally first export the user
dictionary and phrases (the IME's `--export` writes them, still sealed, plus
its key, wrapped under a password the user gives, to the App Group, and the
companion saves them where the user picks) or wipe them (the IME's `--wipe`
deletes its files and its Keychain key); then the companion moves itself to
the Trash and removes the grammar models from the App Group (not the user's
data: a reinstall brings them back).

## 7. Building and signing

| Target | Does |
|---|---|
| `make app` | builds `build/OctoDot.app` with `OctoDotIME.app` inside, signed with the development identity |
| `make install` | development: syncs the IME into `~/Library/Input Methods` as today (reload in place), and the companion into `/Applications` |
| `make dmg-dev` | `build/OctoDot-<version>-dev.dmg`, development-signed, not notarized |
| `make dmg-release` | Developer ID, `--timestamp`, no `get-task-allow`; `notarytool submit --wait`; `stapler staple`; `spctl` check |
| `make uninstall` | section 6, without the dialogs |

`SIGN_PROFILE=dev` (default: Apple Development, team G4JRQAX252) or
`SIGN_PROFILE=release` (Developer ID Application; needs that certificate,
and a notarytool Keychain profile named in `NOTARY_PROFILE`). Signing goes
inside out: the cores, the IME's launcher, `OctoDotIME.app` (its
entitlements), the XPC service, the companion's executable,
`OctoDot.app` (its entitlements); every step `--options runtime`.

`tools/build-dmg.sh`: a staging folder with `OctoDot.app` and an
`Applications` link, a background drawn by a Swift script (an arrow from one
to the other), the Finder window laid out by AppleScript on a writable image
(icon view, fixed bounds and positions, `.background` and `.fseventsd`
hidden), then `hdiutil convert -format UDZO`. `spctl -a -t open --context
context:primary-signature` checks the release image.

The version (`VERSION`, one file) and a build number (the commit count) go
into both bundles' `Info.plist`.

## 8. Verification gates (in `make test`)

1. **Entitlements**: `tools/audit-bundle.sh` on the built app: the IME has
   Hardened Runtime, no network entitlement, no `get-task-allow`, no
   `disable-library-validation`; the companion has no `get-task-allow` in a
   release build; `codesign --verify --deep --strict` on both.
2. **DMG**: `make dmg-dev`, then attach read-only, check `OctoDot.app` (its
   signature, the IME inside) and the `Applications` link, detach.
3. **Setup states**: unit tests of `SetupState` for a fresh install, an
   outdated IME, an installed but disabled one, and a ready one (and the
   old `OctoDot.app`, and a read-only volume), on fake inputs; nothing
   touches the real input sources.
4. **Updates**: unit tests that the verifier accepts a manifest signed by
   the key, and rejects a changed hash, a changed field, an older or equal
   build, a wrong key and a malformed signature.

None of these registers, enables, selects or restarts the real input
method: the live IME is only ever touched by `make install` or by the user
running the companion.

## 9. Order of work

1. The bundles: `OctoDotIME.app` inside `OctoDot.app`, development signing,
   entitlements, the audit (gate 1).
2. `SetupState` and the installer service; the wizard (gate 3).
3. The DMG (gate 2), then the release profile.
4. The updater (gate 4), the input menu's item, uninstall.

## 10. As built

What differs from the plan above, and how far each part was checked on
2026-11-09 (macOS 27.2, team G4JRQAX252, Apple Development signing).

- **Sources.** `macos/Sources/Setup` (the setup state, the update manifest
  and verifier, the installer's protocol, the transfer: shared by the
  companion, the installer and the tests), `Sources/Companion`,
  `Sources/Installer`, `Sources/SetupTests`; in the IME,
  `Sources/IME/Companion.swift` and the four maintenance commands. Identity
  comes from the Makefile's variables, as a generated `Identity.swift`.
- **Settings stay in the IME**; the companion reaches it by distributed
  notifications whose names carry the request (`<id>.showSettings`,
  `<id>.scheme.flypy`, `<id>.charset.full`), which a sandboxed app may post.
  Step D's character set is a setting now, not only Control-G
  (`octo_set_full_charset`, ABI 13; also in Settings → Input).
- **The IME's input menu**: "OctoDot Settings…" and "Check for Updates…"
  (`octodot://update`).
- **Backups** are the user's data sealed under a passphrase (PBKDF2-SHA256,
  600,000 rounds, AES-GCM, `.octodot-backup`); "Restore a Backup…" brings
  one back through `--import`.
- **Builds are all or nothing**: each bundle is assembled in a `.partial`
  folder and moved into place only once signed and verified.

Verified:

- Gate 1: `tools/audit-bundle.sh` passes on the built app, and fails on a
  copy whose IME was re-signed with `network.client`, `get-task-allow` and
  `disable-library-validation`.
- Gate 2: `make dmg-dev` builds a 400 MB UDZO image that `tools/test-dmg.sh`
  verifies, mounts read-only, finds the companion, the IME inside it, the
  grammar model it pins and the `Applications` link in, and detaches. The
  model is 82% of it and barely compresses (zlib 0.885, xz −9e 0.807); LZMA
  (ULMO) saves 9% but takes 14 s instead of 2 to verify, so the image stays UDZO.
- Gates 3 and 4: `build/octo-setup-test`, 29 checks (every setup state, the
  verifier against good and tampered manifests, downgrades, foreign keys).
- The sandboxed companion reaches its unsandboxed installer (`OctoDot
  --facts`), and the installer refuses any other caller (its connections
  carry a code-signing requirement, as do the companion's).
- In the IME's sandbox: `--preflight` (the team-prefixed App Group works
  without a provisioning profile; the Keychain key reads without a prompt
  under the team signature), and `--import` → sealed on disk → `--export` →
  `--wipe` with sample data.
- The release tools: a manifest signed by `octo-update-sign` verifies; one
  with a changed field, or replayed to the same build, does not.
- The wizard opens at its input method step on this Mac.

Not verified here:

- Notarization and stapling (`make dmg-release`): this Keychain has no
  Developer ID Application certificate.
- The Finder layout of the disk image: AppleScript to Finder needs the
  terminal to be allowed to control Finder (macOS asks once); the gate ran
  with `OCTODOT_DMG_LAYOUT=0`.
- The first install on this Mac, which removes the old input method and
  changes the input sources, waits for the owner (`make install`, or opening
  the app).
- A real update: no release is published and no signing key made yet
  (`make release-key`, then `make dmg-release` and `make appcast`).

