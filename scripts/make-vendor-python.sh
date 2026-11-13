#!/usr/bin/env bash
# Builds the Python bundles: one per architecture, in vendor/python/<arch>/.
# Each contains /opt/python4Jup: the portable Python of lists/python-standalone.txt
# with exactly the packages of lists/python-requirements.lock, ready to extract.
# The same bundle serves every distribution of that architecture whose glibc is at
# least the one it was built on (ubuntu:20.04, glibc 2.31).
#
# VARIANT=legacy builds vendor/python-legacy/<arch>/ on ubuntu:16.04 (glibc 2.23),
# for older distributions (Ubuntu 16.04, 18.04): same Python, same lock (or
# lists/python-requirements-legacy.lock if present). The builder picks the bundle
# by the glibc of each image; the current one is never changed by this.
#
# Usage (from the builder folder):
#   scripts/make-vendor-python.sh                       amd64 + arm64
#   ARCHS=amd64 scripts/make-vendor-python.sh           only amd64
#   VARIANT=legacy scripts/make-vendor-python.sh        the legacy bundles
# arm64 on an amd64 machine needs QEMU (installed by JupyDo's first_start.sh).
set -uo pipefail
FAILED=()
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-amd64 arm64}"
if [ "${VARIANT:-current}" = legacy ]; then
  BUILD_IMAGE="ubuntu:16.04"   # glibc 2.23: for Ubuntu 16.04 / 18.04 images
  OUT="python-legacy"
  LOCK_FILE="lists/python-requirements-legacy.lock"
  [ -f "$LOCK_FILE" ] || LOCK_FILE="lists/python-requirements.lock"
else
  BUILD_IMAGE="ubuntu:20.04"   # glibc 2.31: the wheels pip picks work on every newer distro
  OUT="python"
  LOCK_FILE="lists/python-requirements.lock"
fi
echo "Python bundle ${OUT}: built on ${BUILD_IMAGE}, packages from ${LOCK_FILE}"

mkdir -p "vendor/${OUT}" vendor/.downloads
for arch in $ARCHS; do
  case "$arch" in
    amd64) triple=x86_64 ;;
    arm64) triple=aarch64 ;;
    *) echo "ERROR: unsupported architecture $arch" >&2; exit 1 ;;
  esac
  echo
  echo "=== python bundle ${arch} ==="
  tgz="vendor/.downloads/python-standalone-${triple}.tar.gz"
  scripts/lib/python-standalone.sh "$triple" "$tgz"
  docker pull --quiet --platform "linux/${arch}" "$BUILD_IMAGE" >/dev/null
  docker run --rm --platform "linux/${arch}" \
    -e PYTHON_TGZ=/in/python.tar.gz -e LOCK=/in/requirements.lock \
    -e OUT_DIR="/out/${arch}" -e EXPECTED_ARCH="$arch" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "${ROOT}/${tgz}:/in/python.tar.gz:ro" \
    -v "${ROOT}/${LOCK_FILE}:/in/requirements.lock:ro" \
    -v "${ROOT}/scripts/lib/python-bundle-inner.sh:/python-bundle-inner.sh:ro" \
    -v "${ROOT}/vendor/${OUT}:/out" \
    "$BUILD_IMAGE" bash /python-bundle-inner.sh
  [ -f "vendor/${OUT}/${arch}/.complete" ] || { echo "ERROR: bundle ${OUT}-${arch} failed, going on with the others" >&2; FAILED+=("${OUT}-${arch}"); }
done

echo
echo "=== ${OUT} bundles ==="
for dir in vendor/${OUT}/*/; do
  [ -f "$dir/.complete" ] && { echo "--- $(basename "$dir")"; cat "$dir/manifest.txt"; }
done

if [ "${#FAILED[@]}" -gt 0 ]; then
  echo
  echo "FAILED bundles: ${FAILED[*]}"
  echo "(arm64 on an amd64 machine: check QEMU with  docker run --rm --platform linux/arm64 ubuntu:22.04 uname -m)"
  exit 1
fi
