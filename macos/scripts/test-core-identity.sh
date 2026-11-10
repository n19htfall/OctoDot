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

# The source TSV may change without a fresh timestamp. Rebuild the actual
# index rule, then check that its content participates in the core identity.
printf '苹果\tapple\n檎\tapple\n' > "$work/glossary.tsv"
printf '苹果\tping guo\t100\tsource\n檎\tqin\t1\tsource\n' > "$work/lexicon.tsv"
build_index() {
    make --no-print-directory "$work/glossary.sqlite3" \
        GLOSSARY_INDEX="$work/glossary.sqlite3" GLOSSARY_STAMP="$work/glossary.inputs" \
        GLOSSARY_TSV="$work/glossary.tsv" GLOSSARY_WEIGHTS="$work/lexicon.tsv" >/dev/null
}
build_index
test "$(sqlite3 "$work/glossary.sqlite3" "select translation from en where term='apple'")" = '苹果'
old=$(./scripts/core-identity.sh "$work/grammar" "$work/engine" "$work/glossary.sqlite3")
printf '苹果\tfruit\n檎\tapple\n' > "$work/glossary.tsv"
touch -r "$work/glossary.inputs" "$work/glossary.tsv"
build_index
new=$(./scripts/core-identity.sh "$work/grammar" "$work/engine" "$work/glossary.sqlite3")
test "$old" != "$new"
test "$(sqlite3 "$work/glossary.sqlite3" "select translation from en where term='apple'")" = '檎'
printf 'ok    glossary-only changes rebuild the index and change the core identity\n'

# The system make has second-resolution comparisons. A changed identity must
# be newer than an app built in that same second, or its bundle is skipped.
printf 'built bundle' > "$work/ime.app"
printf 'changed input' > "$work/engine"
make --no-print-directory "$stamp" CORE_ID="$stamp" CORE_INPUTS="$work/engine" \
    CORE_DATA="$work/glossary.sqlite3" IMAGES="$work" GRAMMAR_NAME=grammar \
    IME_APP="$work/ime.app" >/dev/null
test "$(stat -f %m "$stamp")" -gt "$(stat -f %m "$work/ime.app")"
printf 'ok    a changed identity is newer than a bundle built in the same second\n'
