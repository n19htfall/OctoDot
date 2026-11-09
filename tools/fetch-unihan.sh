#!/usr/bin/env bash
# Fetches the Unihan database pinned in data/unihan.lock into
# .data/unihan/<version>/, checks each file's SHA-256, and extracts the two
# tables octo-prep reads. Developer machines and CI only: the IME itself
# never downloads anything.
#
#   tools/fetch-unihan.sh                    fetch and verify (skips good files)
#   tools/fetch-unihan.sh --relock VERSION   pin Unicode VERSION instead: download
#                                            its files and rewrite the lock
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/data/unihan.lock"
TABLES=(Unihan_OtherMappings.txt Unihan_IRGSources.txt)

VERSION=""
FILES=() HASHES=()
while read -r kind a b; do
    case "$kind" in
        version) VERSION="$a" ;;
        file) HASHES+=("$a"); FILES+=("$b") ;;
    esac
done < <(grep -v '^[[:space:]]*#' "$LOCK")
[[ -n "$VERSION" && ${#FILES[@]} -gt 0 ]] || { echo "error: $LOCK names no version or files" >&2; exit 1; }

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

url() {  # version file
    case "$2" in
        license.txt) echo "https://www.unicode.org/license.txt" ;;
        *) echo "https://www.unicode.org/Public/$1/ucd/$2" ;;
    esac
}

download() {  # url dest
    mkdir -p "$(dirname "$2")"
    curl -fsSL --retry 3 -o "$2.part" "$1"
    mv "$2.part" "$2"
}

if [[ "${1:-}" == "--relock" ]]; then
    new_version="${2:?usage: fetch-unihan.sh --relock VERSION}"
    dest="$ROOT/.data/unihan/$new_version"
    new_hashes=()
    for i in "${!FILES[@]}"; do
        download "$(url "$new_version" "${FILES[$i]}")" "$dest/${FILES[$i]}"
        new_hashes+=("$(sha256 "$dest/${FILES[$i]}")")
        change="unchanged"
        [[ "${new_hashes[$i]}" == "${HASHES[$i]}" ]] || change="changed"
        printf '%-9s %10s bytes  %s\n' "$change" "$(stat -f %z "$dest/${FILES[$i]}")" "${FILES[$i]}"
    done
    {
        sed -n '/^#/p' "$LOCK"
        echo "version $new_version"
        for i in "${!FILES[@]}"; do echo "file ${new_hashes[$i]} ${FILES[$i]}"; done
    } >"$LOCK.new"
    mv "$LOCK.new" "$LOCK"
    echo "pinned Unicode $new_version in data/unihan.lock; review the import report before committing"
    exit 0
fi

dest="$ROOT/.data/unihan/$VERSION"
fetched=0
for i in "${!FILES[@]}"; do
    out="$dest/${FILES[$i]}"
    [[ -f "$out" && "$(sha256 "$out")" == "${HASHES[$i]}" ]] && continue
    download "$(url "$VERSION" "${FILES[$i]}")" "$out"
    got="$(sha256 "$out")"
    if [[ "$got" != "${HASHES[$i]}" ]]; then
        rm -f "$out"
        echo "error: ${FILES[$i]} has SHA-256 $got; data/unihan.lock pins ${HASHES[$i]}" >&2
        exit 1
    fi
    fetched=$((fetched + 1))
    rm -f "${TABLES[@]/#/$dest/}"           # re-extract from the new archive
done
# Only the named members, into this version's own directory.
missing=()
for t in "${TABLES[@]}"; do [[ -f "$dest/$t" ]] || missing+=("$t"); done
if [[ ${#missing[@]} -gt 0 ]]; then
    unzip -q -o "$dest/Unihan.zip" "${missing[@]}" -d "$dest"
fi
echo "unihan $VERSION: ${#FILES[@]} files verified ($fetched downloaded) in .data/unihan/$VERSION"
