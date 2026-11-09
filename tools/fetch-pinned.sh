#!/usr/bin/env bash
# Fetches the files a lock pins (data/accuracy.lock, data/grammar.lock) into
# a directory under .data/, checking each file's SHA-256. Developer machines
# and CI only: the IME never downloads anything.
#
#   tools/fetch-pinned.sh LOCK DEST            fetch and verify (skips good files)
#   tools/fetch-pinned.sh LOCK DEST --rehash   download every file again and
#                                              rewrite its hash (after moving a URL,
#                                              or when upstream replaced a file)
#
# A lock's lines: "file <sha256> <path under DEST> <url>"; "#" starts a comment.
set -euo pipefail

LOCK="${1:?usage: fetch-pinned.sh LOCK DEST [--rehash]}"
DEST="${2:?usage: fetch-pinned.sh LOCK DEST [--rehash]}"

HASHES=() NAMES=() URLS=()
while read -r kind hash name url; do
    [[ "$kind" == "file" ]] || continue
    HASHES+=("$hash"); NAMES+=("$name"); URLS+=("$url")
done < <(grep -v '^[[:space:]]*#' "$LOCK")
[[ ${#NAMES[@]} -gt 0 ]] || { echo "error: $LOCK names no files" >&2; exit 1; }

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

download() {  # url dest
    mkdir -p "$(dirname "$2")"
    curl -fsSL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
}

if [[ "${3:-}" == "--rehash" ]]; then
    {
        sed -n '/^#/p' "$LOCK"
        for i in "${!NAMES[@]}"; do
            download "${URLS[$i]}" "$DEST/${NAMES[$i]}"
            echo "file $(sha256 "$DEST/${NAMES[$i]}") ${NAMES[$i]} ${URLS[$i]}"
        done
    } >"$LOCK.new"
    mv "$LOCK.new" "$LOCK"
    echo "rehashed $LOCK; review what changed before committing"
    exit 0
fi

for i in "${!NAMES[@]}"; do
    out="$DEST/${NAMES[$i]}"
    [[ -f "$out" && "$(sha256 "$out")" == "${HASHES[$i]}" ]] && continue
    download "${URLS[$i]}" "$out"
    got="$(sha256 "$out")"
    if [[ "$got" != "${HASHES[$i]}" ]]; then
        rm -f "$out"
        echo "error: ${NAMES[$i]} has SHA-256 $got; $LOCK pins ${HASHES[$i]}" >&2
        exit 1
    fi
done
