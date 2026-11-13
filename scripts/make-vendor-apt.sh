#!/usr/bin/env bash
# Builds the offline apt bundles: one per distribution (lists/distros.txt) and
# architecture, in vendor/apt/<distro>-<version>-<arch>/.
# Each bundle contains every package of lists/apt-*.txt with its complete
# dependency closure, as a local apt repository.
#
# Usage (from the builder folder):
#   scripts/make-vendor-apt.sh                    all distros, amd64 + arm64
#   ARCHS=amd64 scripts/make-vendor-apt.sh        only amd64
#   scripts/make-vendor-apt.sh ubuntu:24.04       only one distro
#   FORCE=1 scripts/make-vendor-apt.sh            rebuild also bundles already done
#   NEW=1 scripts/make-vendor-apt.sh ubuntu:24.04 a NEW bundle next to the existing one,
#                                                 vendor/apt/<distro>-<version>-<arch>-<today>,
#                                                 for images newer than it (the old one is
#                                                 never touched; build-image.sh picks per image)
# Bundles already complete are skipped: run it to add only the missing ones.
# arm64 on an amd64 machine needs QEMU (installed by JupyDo's first_start.sh).
set -uo pipefail
FAILED=()
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-amd64 arm64}"

if [ $# -gt 0 ]; then
  DISTROS=("$@")
else
  mapfile -t DISTROS < <(grep -v '^\s*#' lists/distros.txt | grep -v '^\s*$')
fi

mkdir -p vendor/apt
for image in "${DISTROS[@]}"; do
  id="${image%%:*}"; version="${image#*:}"
  for arch in $ARCHS; do
    key="${id}-${version}-${arch}"
    [ "${NEW:-0}" = 1 ] && key="${key}-$(date +%F)"
    echo
    echo "=== apt bundle ${key} ==="
    if [ -f "vendor/apt/${key}/.complete" ] && [ "${FORCE:-0}" != 1 ]; then
      echo "already done: skipped (FORCE=1 to rebuild it)"
      continue
    fi
    docker pull --quiet --platform "linux/${arch}" "$image" >/dev/null
    docker run --rm --platform "linux/${arch}" \
      -e LISTS_DIR=/lists -e OUT_DIR="/out/${key}" \
      -e EXPECTED_ID="$id" -e EXPECTED_VERSION="$version" -e EXPECTED_ARCH="$arch" \
      -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
      -v "${ROOT}/lists:/lists:ro" \
      -v "${ROOT}/scripts/lib/apt-bundle-inner.sh:/apt-bundle-inner.sh:ro" \
      -v "${ROOT}/vendor/apt:/out" \
      "$image" bash /apt-bundle-inner.sh
    [ -f "vendor/apt/${key}/.complete" ] || { echo "ERROR: bundle ${key} failed, going on with the others" >&2; FAILED+=("${key}"); }
  done
done

echo
echo "=== apt bundles ==="
for dir in vendor/apt/*/; do
  [ -f "$dir/.complete" ] && printf '%-24s %s packages, %s\n' "$(basename "$dir")" \
    "$(grep '^debs=' "$dir/platform.txt" | cut -d= -f2)" "$(du -sh "$dir" | cut -f1)"
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo
  echo "FAILED bundles: ${FAILED[*]}"
  echo "(arm64 on an amd64 machine: check QEMU with  docker run --rm --platform linux/arm64 ubuntu:22.04 uname -m)"
  exit 1
fi
