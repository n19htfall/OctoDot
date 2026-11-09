#!/bin/bash
# The entitlement and signature audit (docs/distribution-and-onboarding.md,
# section 8, gate 1), on a built OctoDot.app:
#
#   tools/audit-bundle.sh build/OctoDot.app TEAM_ID [dev|release]
#
# The input method, which sees every key typed, must be sandboxed, with no
# network entitlement, no get-task-allow, no library-validation or other
# runtime exceptions, no third-party code, and the Hardened Runtime; the
# companion and its installer must be signed by the same team, with the
# Hardened Runtime, and no get-task-allow; a release must be Developer ID
# signed with a secure timestamp. Every bundle must pass
# codesign --verify --deep --strict. Exit 1 on the first broken rule's line,
# after listing all of them.
set -u
APP=${1:?usage: audit-bundle.sh OctoDot.app TEAM_ID [dev|release]}
TEAM=${2:?team ID}
PROFILE=${3:-dev}
IME="$APP/Contents/Resources/OctoDotIME.app"
XPC="$APP/Contents/XPCServices/OctoDotInstaller.xpc"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
failures=0

check() {   # check <ok: 0 or 1> <what>
    if [ "$1" = 0 ]; then echo "ok    $2"; else echo "FAIL  $2"; failures=$((failures + 1)); fi
}

entitlements() {    # entitlements <code> -> path of its entitlements plist (empty dict if none)
    local out="$WORK/$(echo "$1" | shasum | cut -c1-8).plist"
    codesign -d --entitlements - --xml "$1" > "$out" 2>/dev/null
    [ -s "$out" ] || echo '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$out"
    echo "$out"
}

has() {     # has <plist> <key>: 0 if the key is present
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" >/dev/null 2>&1
}

value() {   # value <plist> <key>
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

runtime() {     # runtime <code>: 0 if signed with the Hardened Runtime
    codesign -dv "$1" 2>&1 | grep -q 'flags=.*runtime'
}

team() {        # team <code>
    codesign -dv "$1" 2>&1 | sed -n 's/^TeamIdentifier=//p'
}

for code in "$APP" "$XPC" "$IME"; do
    name=${code#"$APP"/}
    [ "$code" = "$APP" ] && name=OctoDot.app
    codesign --verify --deep --strict "$code" 2>/dev/null; check $? "$name: codesign --verify --deep --strict"
    runtime "$code"; check $? "$name: Hardened Runtime"
    [ "$(team "$code")" = "$TEAM" ]; check $? "$name: signed by team $TEAM"
    plist=$(entitlements "$code")
    ! has "$plist" com.apple.security.get-task-allow; check $? "$name: no get-task-allow"
done
for core in "$IME"/Contents/Frameworks/*; do
    runtime "$core"; check $? "OctoDotIME.app: $(basename "$core"): Hardened Runtime"
    [ "$(team "$core")" = "$TEAM" ]; check $? "OctoDotIME.app: $(basename "$core"): signed by team $TEAM"
done

# The input method.
ime=$(entitlements "$IME")
[ "$(value "$ime" com.apple.security.app-sandbox)" = true ]; check $? "OctoDotIME.app: sandboxed"
bad=$(/usr/libexec/PlistBuddy -c Print "$ime" 2>/dev/null |
      grep -oE 'com\.apple\.security\.(network\.[a-z]+|cs\.[a-z-]+|files\.[a-z.-]+|device\.[a-z-]+|automation\.[a-z-]+|personal-information\.[a-z-]+|temporary-exception\.(files|apple-events|shared-preference)[a-z.-]*)' | sort -u)
[ -z "$bad" ]; check $? "OctoDotIME.app: no network, file, device, automation, personal-data or runtime-exception entitlements${bad:+ (has: $(echo $bad))}"
extra=$(ls "$IME/Contents/Frameworks" | grep -v '^OctoDotCore-[0-9a-f]*\.dylib$')
[ -z "$extra" ]; check $? "OctoDotIME.app: no code but its own cores (no updater or other frameworks)${extra:+ (has: $extra)}"
! grep -rqiE 'sparkle|SUFeedURL' "$IME/Contents/Info.plist" 2>/dev/null; check $? "OctoDotIME.app: no updater settings"

# The companion and its installer.
app=$(entitlements "$APP")
[ "$(value "$app" com.apple.security.app-sandbox)" = true ]; check $? "OctoDot.app: sandboxed"
! has "$app" com.apple.security.network.server; check $? "OctoDot.app: no incoming network"
xpc=$(entitlements "$XPC")
! /usr/libexec/PlistBuddy -c Print "$xpc" 2>/dev/null | grep -q 'network'; check $? "OctoDotInstaller.xpc: no network entitlement"

if [ "$PROFILE" = release ]; then
    for code in "$APP" "$XPC" "$IME"; do
        codesign -dv --verbose=4 "$code" 2>&1 | grep -q '^Authority=Developer ID Application'
        check $? "${code#"$APP"/}: Developer ID"
        codesign -dv --verbose=4 "$code" 2>&1 | grep -q '^Timestamp='
        check $? "${code#"$APP"/}: secure timestamp"
    done
fi

[ $failures -eq 0 ] && echo "audit: all rules hold" || echo "audit: $failures rule(s) broken"
exit $((failures > 0))
