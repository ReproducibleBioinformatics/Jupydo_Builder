#!/usr/bin/env bash
# Builds the kernel libraries (lists/kernel-libs.txt): ipykernel and its dependencies
# for every Python version and architecture, in vendor/kernel-libs/<arch>/cp3XY/.
# Binary packages only, for the oldest glibc possible (manylinux2014 = glibc 2.17);
# if a Python version cannot be resolved that way, newer glibc builds are accepted
# and the glibc needed is written in its manifest (the image build checks it).
# Runs on this machine, no Docker: pip only downloads ready-made packages.
#
# Usage (from the builder folder):
#   scripts/make-vendor-kernel-libs.sh              amd64 + arm64
#   ARCHS=amd64 scripts/make-vendor-kernel-libs.sh  only amd64
#   FORCE=1 ...                                     rebuild also sets already done
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-amd64 arm64}"
FAILED=()

# pip from the same portable Python the bundles use (any version can download for any other)
mkdir -p vendor/.downloads
HOST="$(uname -m)"
TOOL_TGZ="vendor/.downloads/python-standalone-${HOST}.tar.gz"
[ -f "$TOOL_TGZ" ] || scripts/lib/python-standalone.sh "$HOST" "$TOOL_TGZ" || exit 1
TOOL="$(mktemp -d)"; trap 'rm -rf "$TOOL"' EXIT
tar -xzf "$TOOL_TGZ" -C "$TOOL"
PY="$TOOL/python/bin/python3"

platforms() {  # $1 = arch, $2 = strict|relaxed
  local m; m="$([ "$1" = arm64 ] && echo aarch64 || echo x86_64)"
  echo "--platform manylinux2014_${m} --platform manylinux_2_17_${m}"
  [ "$2" = relaxed ] && echo "--platform manylinux_2_24_${m} --platform manylinux_2_26_${m} --platform manylinux_2_28_${m}"
}

for arch in $ARCHS; do
  for version in $(sed 's/#.*//' lists/kernel-libs.txt | awk 'NF'); do
    tag="cp${version/./}"
    out="vendor/kernel-libs/${arch}/${tag}"
    echo
    echo "=== kernel libs ${arch} ${tag} ==="
    if [ -f "${out}/.complete" ] && [ "${FORCE:-0}" != 1 ]; then
      echo "already done: skipped (FORCE=1 to rebuild it)"; continue
    fi
    rm -rf "$out"; mkdir -p "$out"
    glibc=2.17
    for mode in strict relaxed; do
      rm -rf "${out}/site"
      # shellcheck disable=SC2046
      if "$PY" -m pip install --quiet --disable-pip-version-check --no-compile \
           --target "${out}/site" --only-binary=:all: --implementation cp \
           --python-version "$version" --abi "$tag" --abi abi3 --abi none \
           $(platforms "$arch" "$mode") --platform any ipykernel > "${out}/pip.log" 2>&1; then
        break
      fi
      glibc=""
    done
    # pip judged the conditional dependencies with ITS Python version, not the target's
    # (e.g. exceptiongroup, needed by IPython only below 3.11): add what is missing,
    # one level at a time, until nothing is
    machine="$([ "$arch" = arm64 ] && echo aarch64 || echo x86_64)"
    for round in 1 2 3 4 5 6; do
      mapfile -t missing < <("$PY" scripts/lib/missing-deps.py "${out}/site" "$version" "$machine")
      [ "${#missing[@]}" -gt 0 ] && [ -n "${missing[0]}" ] || break
      echo "  adding for Python ${version}: ${missing[*]}"
      # shellcheck disable=SC2046
      "$PY" -m pip install --quiet --disable-pip-version-check --no-compile --no-deps \
        --target "${out}/site" --only-binary=:all: --implementation cp \
        --python-version "$version" --abi "$tag" --abi abi3 --abi none \
        $(platforms "$arch" relaxed) --platform any "${missing[@]}" >> "${out}/pip.log" 2>&1 \
        || { echo "ERROR: could not add ${missing[*]} for Python ${version} ${arch}" >&2; break; }
    done
    if [ ! -d "${out}/site/ipykernel" ]; then
      echo "ERROR: ipykernel could not be resolved for Python ${version} ${arch} (see ${out}/pip.log)" >&2
      FAILED+=("${arch}-${tag}"); continue
    fi
    # glibc needed: for each package the oldest glibc its wheel supports (a wheel can
    # list several), then the newest of those over all packages
    if [ -z "$glibc" ]; then
      glibc="$(for w in "${out}"/site/*.dist-info/WHEEL; do
                 grep -o 'manylinux[_0-9a-z]*' "$w" | sed 's/manylinux2014.*/2.17/; s/manylinux2010.*/2.12/;
                   s/manylinux1.*/2.5/; s/manylinux_2_\([0-9]*\).*/2.\1/' | sort -V | head -1
               done | sort -V | tail -1)"
      glibc="${glibc:-2.17}"
    fi
    rm -rf "${out}/site/bin"   # console scripts: not needed, the kernel is started with -c
    (cd "${out}/site" && find . -type f | sort | xargs sha256sum) > "${out}/SHA256SUMS"
    {
      echo "python=${version}"
      echo "architecture=${arch}"
      echo "min_glibc=${glibc}"
      echo "packages=$(ls "${out}/site" | grep '\.dist-info$' | sed 's/\.dist-info$//' | tr '\n' ' ')"
      echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "${out}/manifest.txt"
    touch "${out}/.complete"
    echo "OK ${arch} ${tag}: $(grep -o 'ipykernel-[0-9.]*' "${out}/manifest.txt"), glibc >= ${glibc}, $(du -sh "${out}/site" | cut -f1)"
  done
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo; echo "FAILED: ${FAILED[*]}"; exit 1
fi
