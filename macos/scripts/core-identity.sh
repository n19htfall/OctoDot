#!/bin/sh
# The grammar pin contains the model size; the lock in the remaining inputs
# identifies its content. Hash the filenames too, so additions and removals
# of optional data files change the generation.
set -eu
model=$1
shift
size=$(stat -f '%z' "$model")
hashes=$(shasum -a 256 "$@")
{
    printf '%s\n%s\n' "$size" "$hashes"
} | shasum -a 256 | cut -c1-12
