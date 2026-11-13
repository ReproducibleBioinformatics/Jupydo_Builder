#!/usr/bin/env bash
# Which Python bundle an image uses: the first of vendor/python (current) and
# vendor/python-legacy built on a glibc not newer than the image's (a program built
# on an older glibc runs on a newer one, not the other way round).
# Usage: pick-python.sh <arch> <glibc of the image>   -> prints "python" or "python-legacy"
set -euo pipefail
cd "$(dirname "$0")/../.."
ARCH="$1"; GLIBC="$2"
for name in python python-legacy; do
  dir="vendor/${name}/${ARCH}"
  [ -f "${dir}/.complete" ] && [ -f "${dir}/manifest.txt" ] || continue
  built="$(sed -n 's/^built_on=.*(glibc \([0-9.]*\)).*/\1/p' "${dir}/manifest.txt")"
  [ -n "$built" ] || continue
  if [ "$(printf '%s\n%s\n' "$built" "$GLIBC" | sort -V | head -1)" = "$built" ]; then
    echo "$name"; exit 0
  fi
done
echo "ERROR: no Python bundle for glibc ${GLIBC} on ${ARCH} (vendor/python, vendor/python-legacy)" >&2
exit 1
