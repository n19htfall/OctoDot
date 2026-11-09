#!/usr/bin/env bash
# What happens to the host process when something fails after goose_init.
# goose_init installs process-wide SIGSEGV/SIGBUS handlers and records the
# initializing thread's stack, so each case checks how a failure surfaces:
# exit status, what reaches stderr, and whether macOS writes a crash report
# (~/Library/Logs/DiagnosticReports). Expectations are asserted, so a Goose
# upgrade that changes any of this fails here first.
set -uo pipefail
cd "$(dirname "$0")"

SMOKE=build/octo-smoke
REPORTS="$HOME/Library/Logs/DiagnosticReports"
failures=0

new_reports() {  # crash reports for octo-smoke written after the marker
    find "$REPORTS" -maxdepth 1 -name 'octo-smoke*' -newer "$1" 2>/dev/null
}

run_case() {
    local mode="$1" want_status="$2" want_stderr="$3" want_report="$4"
    local marker stderr status report="no"
    marker="$(mktemp)"
    stderr="$("$SMOKE" --crash="$mode" 2>&1 >/dev/null)"
    status=$?
    # ReportCrash writes asynchronously: wait up to 10 s for an expected
    # report, and 3 s before concluding that none is coming.
    local polls=20
    [[ "$want_report" == "no" ]] && polls=6
    for _ in $(seq "$polls"); do
        if [[ -n "$(new_reports "$marker")" ]]; then report="yes"; break; fi
        sleep 0.5
    done
    rm -f "$marker"

    local verdict="ok  "
    if [[ "$status" != "$want_status" || "$stderr" != *"$want_stderr"* || "$report" != "$want_report" ]]; then
        verdict="FAIL"; failures=$((failures + 1))
    fi
    printf '%s %-14s exit %-3s crash report: %-3s stderr: %s\n' \
        "$verdict" "$mode" "$status" "$report" "$(echo "$stderr" | head -1)"
}

# A fault in host code is not Goose's: its handler must hand it back, so
# the process dies of SIGSEGV (exit 139) and macOS records it normally.
run_case host-segv 139 "" yes
# A failed check in Goose ends the process through _Exit(1): a message on
# stderr naming the source line, and no crash report.
run_case goose-oob 1 "goose runtime error: index 1000 out of bounds" no
# A stack overflow in host code on the goose_init thread lands in Goose's
# handler, which reports it as its own and _exit(1)s: no crash report.
run_case host-overflow 1 "goose runtime error: native call stack overflow" no

exit $((failures > 0))
