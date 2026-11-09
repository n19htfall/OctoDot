#!/usr/bin/env bash
# Builds the pinned Goose compiler (toolchain/goose.lock) from source into
# .toolchain/goose-src/build/goose. A goose on PATH is never used, so every
# machine and CI run compiles the engine with the same compiler and runtime.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=goose.lock
source "$ROOT/toolchain/goose.lock"
SRC="$ROOT/.toolchain/goose-src"
BUILD="$SRC/build"

if [[ ! -d "$SRC/.git" ]]; then
    git clone --quiet --filter=blob:none "$GOOSE_REPO" "$SRC"
fi
git -C "$SRC" fetch --quiet --tags origin

tag_commit="$(git -C "$SRC" rev-parse "${GOOSE_TAG}^{commit}")"
if [[ "$tag_commit" != "$GOOSE_COMMIT" ]]; then
    echo "error: tag $GOOSE_TAG is $tag_commit, but goose.lock pins $GOOSE_COMMIT" >&2
    exit 1
fi
git -C "$SRC" -c advice.detachedHead=false checkout --quiet "$GOOSE_COMMIT"

generator=()
if command -v ninja >/dev/null; then generator=(-G Ninja); fi
if [[ ! -f "$BUILD/CMakeCache.txt" ]]; then
    cmake -S "$SRC" -B "$BUILD" "${generator[@]}" -DCMAKE_BUILD_TYPE=Release >/dev/null
fi
cmake --build "$BUILD" --config Release

"$BUILD/goose" version
