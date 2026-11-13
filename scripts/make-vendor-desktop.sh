#!/usr/bin/env bash
# Builds the Desktop bundles (optional module): one per platform of lists/desktop.txt
# and architecture, in vendor/desktop/<distro>-<version>-<arch>/:
#   debs/        XFCE, TigerVNC... (lists/desktop-packages.txt) + the full closure of
#                their dependencies (offline apt repo)
#   wheels/      the JupyterLab extension (lists/desktop-python.txt) for JupyDo's Python
#   manifest.txt packages, TigerVNC version, what was added
# Usage (from the builder folder):
#   scripts/make-vendor-desktop.sh                     every platform, amd64 + arm64
#   ARCHS=amd64 scripts/make-vendor-desktop.sh         only amd64
#   scripts/make-vendor-desktop.sh ubuntu-24.04        only one platform
#   FORCE=1 scripts/make-vendor-desktop.sh             rebuild also bundles already done
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-amd64 arm64}"
FAILED=()

# pip from the portable Python the bundles use; wheels for JupyDo's Python version
mkdir -p vendor/.downloads vendor/desktop
HOST="$(uname -m)"
TOOL_TGZ="vendor/.downloads/python-standalone-${HOST}.tar.gz"
[ -f "$TOOL_TGZ" ] || scripts/lib/python-standalone.sh "$HOST" "$TOOL_TGZ" || exit 1
TOOL="$(mktemp -d)"; trap 'rm -rf "$TOOL"' EXIT
tar -xzf "$TOOL_TGZ" -C "$TOOL"
PY="$TOOL/python/bin/python3"
PYVER="$(grep '^version=' lists/python-standalone.txt | cut -d= -f2 | cut -d. -f1,2)"   # e.g. 3.12
ABI="cp${PYVER/./}"

wheels() {  # $1 = arch, $2 = folder
  local m; m="$([ "$1" = arm64 ] && echo aarch64 || echo x86_64)"
  local plat=(--platform any)
  for v in 2014 _2_17 _2_24 _2_26 _2_28 _2_31; do plat+=(--platform "manylinux${v}_${m}"); done
  local pipargs=(--quiet --disable-pip-version-check --only-binary=:all: --implementation cp
                 --python-version "$PYVER" --abi "$ABI" --abi abi3 --abi none "${plat[@]}" -d "$2")
  "$PY" -m pip download "${pipargs[@]}" $(sed 's/#.*//' lists/desktop-python.txt | awk 'NF') || return 1
  # pip judges conditional dependencies with its own Python version: add what is missing
  for round in 1 2 3 4 5; do
    rm -rf "$2.site"; mkdir -p "$2.site"
    "$PY" -m pip install --quiet --disable-pip-version-check --no-deps --no-index --target "$2.site" "$2"/*.whl >/dev/null 2>&1
    mapfile -t missing < <("$PY" scripts/lib/missing-deps.py "$2.site" "$PYVER" "$m")
    [ "${#missing[@]}" -gt 0 ] && [ -n "${missing[0]}" ] || break
    echo "  adding for Python ${PYVER}: ${missing[*]}"
    "$PY" -m pip download "${pipargs[@]}" --no-deps "${missing[@]}" || return 1
  done
  rm -rf "$2.site"
}

if [ $# -gt 0 ]; then KEYS=("$@"); else read -r -a KEYS <<< "$(awk '$1 == "platforms" {$1 = ""; print}' lists/desktop.txt)"; fi
for platform in "${KEYS[@]}"; do
  id="${platform%-*}"; version="${platform##*-}"
  for arch in $ARCHS; do
    key="${platform}-${arch}"; out="vendor/desktop/${key}"
    echo; echo "=== desktop bundle ${key} ==="
    if [ -f "${out}/.complete" ] && [ "${FORCE:-0}" != 1 ]; then echo "already done: skipped (FORCE=1 to rebuild it)"; continue; fi
    rm -rf "$out"
    docker pull --quiet --platform "linux/${arch}" "${id}:${version}" >/dev/null
    docker run --rm --platform "linux/${arch}" -e OUT_DIR="/out/${key}" \
      -e EXPECTED_ID="$id" -e EXPECTED_VERSION="$version" -e EXPECTED_ARCH="$arch" \
      -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
      -v "${ROOT}/scripts/lib/desktop-bundle-inner.sh:/desktop-bundle-inner.sh:ro" \
      -v "${ROOT}/lists/desktop-packages.txt:/desktop-packages.txt:ro" \
      -v "${ROOT}/vendor/desktop:/out" \
      "${id}:${version}" bash /desktop-bundle-inner.sh \
      || { echo "ERROR: bundle ${key} failed (logs in ${out}/logs/), going on" >&2; FAILED+=("$key"); continue; }
    mkdir -p "${out}/wheels"
    wheels "$arch" "${out}/wheels" || { echo "ERROR: wheels for ${key} failed" >&2; FAILED+=("$key"); continue; }
    (cd "${out}/wheels" && sha256sum ./*.whl > SHA256SUMS)
    echo "wheels $(ls "${out}/wheels"/*.whl | xargs -n1 basename | tr '\n' ' ')" >> "${out}/manifest.txt"
    (cd "$out" && sha256sum debs/SHA256SUMS wheels/SHA256SUMS > SHA256SUMS)
    touch "${out}/.complete"
  done
done

echo; echo "=== desktop bundles ==="
for dir in vendor/desktop/*/; do
  [ -f "$dir/.complete" ] && printf '%-22s TigerVNC %-14s %s\n' "$(basename "$dir")" "$(grep '^tigervnc' "$dir/manifest.txt" | cut -d' ' -f2)" "$(du -sh "$dir" | cut -f1)"
done
if [ "${#FAILED[@]}" -gt 0 ]; then echo; echo "FAILED: ${FAILED[*]}"; exit 1; fi
