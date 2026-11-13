#!/usr/bin/env bash
# Helper: download + verify the portable Python of lists/python-standalone.txt.
# Usage: python-standalone.sh <x86_64|aarch64> <output .tar.gz>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
conf() { grep "^$1=" "$ROOT/lists/python-standalone.txt" | cut -d= -f2; }
arch="$1"; out="$2"
release="$(conf release)"; version="$(conf version)"; sha="$(conf "sha256_${arch}")"
[ -n "$sha" ] || { echo "ERROR: no checksum for ${arch} in lists/python-standalone.txt" >&2; exit 1; }
name="cpython-${version}%2B${release}-${arch}-unknown-linux-gnu-install_only.tar.gz"
if [ ! -f "$out" ] || ! echo "${sha}  ${out}" | sha256sum -c --status; then
  curl -fsSL -o "$out" "https://github.com/astral-sh/python-build-standalone/releases/download/${release}/${name}"
fi
echo "${sha}  ${out}" | sha256sum -c --status || { echo "ERROR: checksum mismatch for ${name}" >&2; exit 1; }
