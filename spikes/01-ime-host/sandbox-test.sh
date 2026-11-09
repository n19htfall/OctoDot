#!/usr/bin/env bash
# The IME's sandbox, checked from outside the process:
#   1. the real build runs sandboxed, the engine works inside the sandbox,
#      and IMKServer's Mach name is really registered (looked up by an
#      unsandboxed process while the IME holds it);
#   2. a negative control, the same app signed with the sandbox entitlement
#      alone, does NOT get its name registered. That shows the
#      temporary-exception entitlement is what makes IMK work, rather than
#      something incidental.
# IMKServer returns an object even when registration fails, which is why
# the lookup decides, not the app's own view.
set -uo pipefail
cd "$(dirname "$0")"

NAME="$(/usr/libexec/PlistBuddy -c 'Print :InputMethodConnectionName' build/OctoDot.app/Contents/Info.plist)"
failures=0

check_app() {  # app, label, expected lookup result (registered | not registered)
    local app="$1" label="$2" want="$3" verdict json lookup
    "$app/Contents/MacOS/OctoDot" --selftest --hold 3 >build/selftest.json 2>build/selftest.err &
    local pid=$!
    sleep 1
    lookup="$(build/machlookup "$NAME")"
    wait "$pid"
    json="$(cat build/selftest.json)"
    verdict="ok  "
    if [[ "$lookup" != *": $want" || "$json" != *'"ok": true'* ]]; then
        verdict="FAIL"; failures=$((failures + 1))
    fi
    printf '%s %-34s %s | %s\n' "$verdict" "$label" "$json" "${lookup#*: }"
}

check_app build/OctoDot.app "sandbox + mach-register exception" "registered"

rm -rf build/negative && mkdir -p build/negative
ditto build/OctoDot.app build/negative/OctoDot.app
plutil -create xml1 build/negative/sandbox-only.entitlements
plutil -insert com\\.apple\\.security\\.app-sandbox -bool YES build/negative/sandbox-only.entitlements
codesign --force --options runtime --timestamp=none \
    --entitlements build/negative/sandbox-only.entitlements --sign - build/negative/OctoDot.app 2>/dev/null
check_app build/negative/OctoDot.app "negative control: sandbox only" "not registered"

exit $((failures > 0))
