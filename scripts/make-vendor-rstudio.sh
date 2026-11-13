#!/usr/bin/env bash
# Builds the RStudio bundles (optional module): one per platform of lists/rstudio.txt
# and architecture, in vendor/rstudio/<distro>-<version>-<arch>/:
#   debs/        RStudio Server + the full closure of its dependencies (offline apt repo)
#   wheels/      the JupyterLab extension (lists/rstudio-python.txt) for JupyDo's Python
#   manifest.txt URL, version and SHA-256 of the RStudio package, what was added
# Usage (from the builder folder):
#   scripts/make-vendor-rstudio.sh                     every platform, amd64 + arm64
#   ARCHS=amd64 scripts/make-vendor-rstudio.sh         only amd64
#   scripts/make-vendor-rstudio.sh ubuntu-24.04        only one platform
#   FORCE=1 scripts/make-vendor-rstudio.sh             rebuild also bundles already done
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-amd64 arm64}"
FAILED=()

# pip from the portable Python the bundles use; wheels for JupyDo's Python version
mkdir -p vendor/.downloads vendor/rstudio
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
  "$PY" -m pip download "${pipargs[@]}" $(sed 's/#.*//' lists/rstudio-python.txt | awk 'NF') || return 1
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

if [ $# -gt 0 ]; then KEYS=("$@"); else mapfile -t KEYS < <(sed 's/#.*//' lists/rstudio.txt | awk 'NF {print $1}'); fi
for platform in "${KEYS[@]}"; do
  url_t="$(sed 's/#.*//' lists/rstudio.txt | awk -v k="$platform" '$1 == k {print $2}')"
  [ -n "$url_t" ] || { echo "ERROR: ${platform} is not in lists/rstudio.txt" >&2; FAILED+=("$platform"); continue; }
  id="${platform%-*}"; version="${platform##*-}"
  for arch in $ARCHS; do
    key="${platform}-${arch}"; out="vendor/rstudio/${key}"
    echo; echo "=== rstudio bundle ${key} ==="
    if [ -f "${out}/.complete" ] && [ "${FORCE:-0}" != 1 ]; then echo "already done: skipped (FORCE=1 to rebuild it)"; continue; fi
    rm -rf "$out"
    docker pull --quiet --platform "linux/${arch}" "${id}:${version}" >/dev/null
    docker run --rm --platform "linux/${arch}" \
      -e RSTUDIO_URL="${url_t//\{arch\}/$arch}" -e OUT_DIR="/out/${key}" \
      -e EXPECTED_ID="$id" -e EXPECTED_VERSION="$version" -e EXPECTED_ARCH="$arch" \
      -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
      -v "${ROOT}/scripts/lib/rstudio-bundle-inner.sh:/rstudio-bundle-inner.sh:ro" \
      -v "${ROOT}/vendor/rstudio:/out" \
      "${id}:${version}" bash /rstudio-bundle-inner.sh \
      || { echo "ERROR: bundle ${key} failed (logs in ${out}/logs/), going on" >&2; FAILED+=("$key"); continue; }
    mkdir -p "${out}/wheels"
    wheels "$arch" "${out}/wheels" || { echo "ERROR: wheels for ${key} failed" >&2; FAILED+=("$key"); continue; }
    (cd "${out}/wheels" && sha256sum ./*.whl > SHA256SUMS)
    echo "wheels $(ls "${out}/wheels"/*.whl | xargs -n1 basename | tr '\n' ' ')" >> "${out}/manifest.txt"
    # what the builder version is computed from (scripts/lib/builder-version.sh)
    (cd "$out" && sha256sum debs/SHA256SUMS wheels/SHA256SUMS > SHA256SUMS)
    touch "${out}/.complete"
  done
done

echo; echo "=== rstudio bundles ==="
for dir in vendor/rstudio/*/; do
  [ -f "$dir/.complete" ] && printf '%-22s %s  %s\n' "$(basename "$dir")" "$(grep '^version' "$dir/manifest.txt" | cut -d' ' -f2)" "$(du -sh "$dir" | cut -f1)"
done
if [ "${#FAILED[@]}" -gt 0 ]; then echo; echo "FAILED: ${FAILED[*]}"; exit 1; fi
