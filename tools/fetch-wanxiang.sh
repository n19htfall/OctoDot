#!/usr/bin/env bash
# Fetches the 万象拼音 (rime-wanxiang) files pinned in data/wanxiang.lock
# into .data/wanxiang/<tag>/ and checks each one's SHA-256. Developer machines
# and CI only: the IME itself never downloads anything.
#
#   tools/fetch-wanxiang.sh                fetch and verify (skips good files)
#   tools/fetch-wanxiang.sh --relock TAG   pin TAG instead: resolve its commit,
#                                          download the same files, and rewrite
#                                          the lock with their hashes
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/data/wanxiang.lock"

REPO="" TAG="" COMMIT=""
FILES=() HASHES=()
while read -r kind a b; do
    case "$kind" in
        repo) REPO="$a" ;;
        tag) TAG="$a" ;;
        commit) COMMIT="$a" ;;
        file) HASHES+=("$a"); FILES+=("$b") ;;
    esac
done < <(grep -v '^[[:space:]]*#' "$LOCK")
[[ -n "$REPO" && ${#FILES[@]} -gt 0 ]] || { echo "error: $LOCK names no repo or files" >&2; exit 1; }

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

download() {  # commit path dest
    mkdir -p "$(dirname "$3")"
    curl -fsSL --retry 3 -o "$3.part" "https://raw.githubusercontent.com/${REPO#https://github.com/}/$1/$2"
    mv "$3.part" "$3"
}

if [[ "${1:-}" == "--relock" ]]; then
    new_tag="${2:?usage: fetch-wanxiang.sh --relock TAG}"
    refs="$(git ls-remote "$REPO" "refs/tags/$new_tag" "refs/tags/$new_tag^{}")"
    new_commit="$(awk '/\^\{\}$/ { print $1 }' <<<"$refs")"     # annotated: the peeled commit
    [[ -n "$new_commit" ]] || new_commit="$(awk 'NR == 1 { print $1 }' <<<"$refs")"
    [[ -n "$new_commit" ]] || { echo "error: no tag $new_tag in $REPO" >&2; exit 1; }

    dest="$ROOT/.data/wanxiang/$new_tag"
    new_hashes=()
    for i in "${!FILES[@]}"; do
        download "$new_commit" "${FILES[$i]}" "$dest/${FILES[$i]}"
        new_hashes+=("$(sha256 "$dest/${FILES[$i]}")")
        change="unchanged"
        [[ "${new_hashes[$i]}" == "${HASHES[$i]}" ]] || change="changed"
        printf '%-9s %10s bytes  %s\n' "$change" "$(stat -f %z "$dest/${FILES[$i]}")" "${FILES[$i]}"
    done

    {
        sed -n '/^#/p' "$LOCK"
        echo "repo $REPO"
        echo "tag $new_tag"
        echo "commit $new_commit"
        for i in "${!FILES[@]}"; do echo "file ${new_hashes[$i]} ${FILES[$i]}"; done
    } >"$LOCK.new"
    mv "$LOCK.new" "$LOCK"
    echo "pinned $new_tag ($new_commit) in data/wanxiang.lock; review the import report before committing"
    exit 0
fi

dest="$ROOT/.data/wanxiang/$TAG"
fetched=0
for i in "${!FILES[@]}"; do
    out="$dest/${FILES[$i]}"
    [[ -f "$out" && "$(sha256 "$out")" == "${HASHES[$i]}" ]] && continue
    download "$COMMIT" "${FILES[$i]}" "$out"
    got="$(sha256 "$out")"
    if [[ "$got" != "${HASHES[$i]}" ]]; then
        rm -f "$out"
        echo "error: ${FILES[$i]} has SHA-256 $got; data/wanxiang.lock pins ${HASHES[$i]}" >&2
        exit 1
    fi
    fetched=$((fetched + 1))
done
echo "wanxiang $TAG: ${#FILES[@]} files verified ($fetched downloaded) in .data/wanxiang/$TAG"
