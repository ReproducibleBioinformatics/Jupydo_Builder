#!/usr/bin/env bash
# Builds the IGV bundles (optional module), in vendor/igv/<platform>-<arch>/:
#   files/igv-webapp.zip   the IGV-Web app (lists/igv.txt): static files, the same
#                          for every platform and architecture
#   wheels/                the launcher proxy (lists/igv-python.txt) for JupyDo's Python
#   debs/, packages.txt    empty: no system package needed
# Downloaded once (vendor/igv/.arch/<arch>/) and hard-linked into each platform's bundle.
# Usage (from the builder folder):
#   scripts/make-vendor-igv.sh                 amd64 + arm64
#   ARCHS=amd64 scripts/make-vendor-igv.sh     only amd64
#   FORCE=1 scripts/make-vendor-igv.sh         download again
set -uo pipefail
cd "$(dirname "$0")/.."
ARCHS="${ARCHS:-amd64 arm64}"
VERSION="$(awk '$1 == "version" {print $2}' lists/igv.txt)"
URL_T="$(awk '$1 == "url" {print $2}' lists/igv.txt)"
read -r -a PLATFORMS <<< "$(awk '$1 == "platforms" {$1 = ""; print}' lists/igv.txt)"
FAILED=()

# pip from the portable Python the bundles use; wheels for JupyDo's Python version
mkdir -p vendor/.downloads vendor/igv
HOST="$(uname -m)"
TOOL_TGZ="vendor/.downloads/python-standalone-${HOST}.tar.gz"
[ -f "$TOOL_TGZ" ] || scripts/lib/python-standalone.sh "$HOST" "$TOOL_TGZ" || exit 1
TOOL="$(mktemp -d)"; trap 'rm -rf "$TOOL"' EXIT
tar -xzf "$TOOL_TGZ" -C "$TOOL"
PY="$TOOL/python/bin/python3"
PYVER="$(grep '^version=' lists/python-standalone.txt | cut -d= -f2 | cut -d. -f1,2)"
ABI="cp${PYVER/./}"

wheels() {  # $1 = arch, $2 = folder (same logic as the RStudio bundles)
  local m; m="$([ "$1" = arm64 ] && echo aarch64 || echo x86_64)"
  local plat=(--platform any)
  for v in 2014 _2_17 _2_24 _2_26 _2_28 _2_31; do plat+=(--platform "manylinux${v}_${m}"); done
  local pipargs=(--quiet --disable-pip-version-check --only-binary=:all: --implementation cp
                 --python-version "$PYVER" --abi "$ABI" --abi abi3 --abi none "${plat[@]}" -d "$2")
  "$PY" -m pip download "${pipargs[@]}" $(sed 's/#.*//' lists/igv-python.txt | awk 'NF') || return 1
  for round in 1 2 3 4 5; do
    rm -rf "$2.site"; mkdir -p "$2.site"
    "$PY" -m pip install --quiet --disable-pip-version-check --no-deps --no-index --target "$2.site" "$2"/*.whl >/dev/null 2>&1
    mapfile -t missing < <("$PY" scripts/lib/missing-deps.py "$2.site" "$PYVER" "$m")
    [ "${#missing[@]}" -gt 0 ] && [ -n "${missing[0]}" ] || break
    "$PY" -m pip download "${pipargs[@]}" --no-deps "${missing[@]}" || return 1
  done
  rm -rf "$2.site"
}

for arch in $ARCHS; do
  shared="vendor/igv/.arch/${arch}"
  echo; echo "=== IGV-Web ${VERSION} (${arch}) ==="
  if [ ! -f "${shared}/.complete" ] || [ "${FORCE:-0}" = 1 ]; then
    rm -rf "$shared"; mkdir -p "${shared}/files" "${shared}/wheels"
    url="${URL_T//\{version\}/$VERSION}"
    echo "downloading $url"
    curl -fsSL -o "${shared}/files/igv-webapp.zip" "$url" \
      || { echo "ERROR: download failed" >&2; FAILED+=("$arch"); continue; }
    wheels "$arch" "${shared}/wheels" || { echo "ERROR: wheels failed" >&2; FAILED+=("$arch"); continue; }
    (cd "$shared" && find files wheels -type f -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
    touch "${shared}/.complete"
  else
    echo "already done: skipped (FORCE=1 to download again)"
  fi
  for platform in "${PLATFORMS[@]}"; do
    out="vendor/igv/${platform}-${arch}"
    rm -rf "$out"; mkdir -p "${out}/debs"
    cp -al "${shared}/files" "${shared}/wheels" "$out/"
    : > "${out}/packages.txt"
    cp "${shared}/SHA256SUMS" "${out}/SHA256SUMS"
    { echo "igv-webapp ${VERSION} ${URL_T//\{version\}/$VERSION}"
      echo "sha256 $(sha256sum "${shared}/files/igv-webapp.zip" | cut -d' ' -f1)"
      echo "wheels $(ls "${shared}/wheels" | tr '\n' ' ')"; } > "${out}/manifest.txt"
    touch "${out}/.complete"
  done
done

echo; echo "=== igv bundles ==="
for d in vendor/igv/*/; do [ -f "$d/.complete" ] && printf '%-22s %s\n' "$(basename "$d")" "$(du -sh --apparent-size "$d" | cut -f1)"; done
if [ "${#FAILED[@]}" -gt 0 ]; then echo; echo "FAILED: ${FAILED[*]}"; exit 1; fi
