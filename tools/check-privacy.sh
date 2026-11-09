#!/bin/sh
# No typed text in any log (M1's privacy criterion), checked in the source:
#
#   engine/ and macos/engine/ (Goose that runs inside the IME)
#     - prints nothing: no print, write_stdout or write_stderr
#     - aborts only with a fixed message: abort("..."), never text built at
#       run time (a contained worker's abort message reaches the host)
#   engine/*.h (the engine's C, compiled into it)
#     - prints and logs nothing: no printf, fprintf, puts, syslog or os_log
#   macos/Sources/IME, Shared and Launcher (Swift inside the IME)
#     - logs only through Logger (no print outside the maintenance commands,
#       no NSLog), where an interpolated value is private unless marked
#     - marks a value public only from an allowed list of names that never
#       carry user text: statuses, scheme ids, counts, core file names and
#       why one did not load
#
# Tests, tools, benchmarks and fuzz targets may print: they never see what a
# user types.
set -u
cd "$(dirname "$0")/.."
failed=0

report() {
    echo "privacy: $1"
    failed=1
}

for f in engine/*.goose macos/engine/*.goose; do
    grep -n -E '(^|[^_a-z])(print|write_stdout|write_stderr)\(' "$f" | while IFS= read -r line; do
        echo "privacy: $f:$line: engine code prints"
    done | grep . && failed=1
    grep -n -E '(^|[^_a-z])abort\(' "$f" | grep -v -E 'abort\("[^"]*"\)' | while IFS= read -r line; do
        echo "privacy: $f:$line: abort with a message built at run time"
    done | grep . && failed=1
done

for f in engine/*.h; do
    grep -n -E '(^|[^_a-zA-Z])(printf|fprintf|puts|fputs|syslog|os_log)\(' "$f" | while IFS= read -r line; do
        echo "privacy: $f:$line: engine C prints or logs"
    done | grep . && failed=1
done

allowed='status|scheme|abnormalExits|core|next|reason|why|live|taken'
for f in macos/Sources/IME/*.swift macos/Sources/Shared/*.swift macos/Sources/Launcher/*.swift; do
    case "$f" in
        */Maintenance.swift|*/Commands.swift) ;;
        *) grep -n -E '(^|[^_a-zA-Z.])print\(' "$f" | while IFS= read -r line; do
               echo "privacy: $f:$line: print in the IME (use Logger)"
           done | grep . && failed=1 ;;
    esac
    grep -n -E 'NSLog\(|os_log\(' "$f" | while IFS= read -r line; do
        echo "privacy: $f:$line: NSLog or os_log (use Logger, private by default)"
    done | grep . && failed=1
    grep -n 'privacy: \.public' "$f" | grep -v -E "\\\\\\(($allowed)[^a-zA-Z_]" | while IFS= read -r line; do
        echo "privacy: $f:$line: a value marked public that is not on the allowed list ($allowed)"
    done | grep . && failed=1
done

if [ "$failed" -ne 0 ]; then
    exit 1
fi
echo "ok    privacy: no engine prints (Goose or C), fixed abort messages, IME logs private by default"
