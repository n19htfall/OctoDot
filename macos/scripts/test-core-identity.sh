#!/bin/sh
set -eu
work=$(mktemp -d "${TMPDIR:-/tmp}/octodot-core-id.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
printf 'engine' > "$work/engine"
printf 'dictionary' > "$work/dictionary.img"
printf 'weights' > "$work/rerank.weights"
printf 'model' > "$work/grammar"
printf 'grammar pin' > "$work/grammar.lock"
identity() {
    ./scripts/core-identity.sh "$work/grammar" "$work/engine" "$work/dictionary.img" "$work/rerank.weights" "$work/grammar.lock"
}
first=$(identity)
printf 'dictionary changed' > "$work/dictionary.img"
second=$(identity)
test "$first" != "$second"
printf 'weights changed' > "$work/rerank.weights"
third=$(identity)
test "$second" != "$third"
printf 'different grammar pin' > "$work/grammar.lock"
fourth=$(identity)
test "$third" != "$fourth"
printf 'larger model' > "$work/grammar"
fifth=$(identity)
test "$fourth" != "$fifth"
test "$fifth" = "$(identity)"
printf 'ok    core identity follows dictionary, model and grammar-pin changes\n'

# Exercise the actual Makefile stamp too, including changes which timestamps
# alone cannot detect and removal of an optional image.
stamp="$work/core.identity"
stamp_with() {
    make --no-print-directory "$stamp" CORE_ID="$stamp" CORE_INPUTS="$work/engine" \
        CORE_DATA="$1" IMAGES="$work" GRAMMAR_NAME=grammar >/dev/null
}
stamp_with "$work/dictionary.img $work/rerank.weights"
old=$(cat "$stamp")
printf 'same timestamp, new dictionary' > "$work/dictionary.img"
touch -r "$stamp" "$work/dictionary.img"
stamp_with "$work/dictionary.img $work/rerank.weights"
changed=$(cat "$stamp")
test "$old" != "$changed"
stamp_with "$work/dictionary.img"
test "$changed" != "$(cat "$stamp")"
printf 'ok    Makefile refreshes the identity when data changes or disappears\n'
