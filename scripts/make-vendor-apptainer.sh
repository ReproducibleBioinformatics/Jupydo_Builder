#!/usr/bin/env bash
# Builds the Apptainer bundles (optional module): one per distribution
# (lists/distros.txt) and architecture, in vendor/apptainer/<distro>-<version>-<arch>/.
# Apptainer (lists/apptainer.txt) is compiled from its official source release with
# the helper programs of the official packages, against each distribution's libraries.
# Each bundle is self-contained: it also carries the system packages Apptainer needs
# (lists/apptainer-packages.txt) as a small offline apt repository.
#
# Usage (from the builder folder):
#   scripts/make-vendor-apptainer.sh                    all distros, amd64 + arm64
#   ARCHS=amd64 scripts/make-vendor-apptainer.sh        only amd64
#   scripts/make-vendor-apptainer.sh ubuntu:24.04       only one distro
#   FORCE=1 scripts/make-vendor-apptainer.sh            rebuild also bundles already done
# Bundles already complete are skipped (each one takes long, arm64 under QEMU).
# Long: Go and Apptainer are compiled for each one (arm64 under QEMU: much longer).
set -uo pipefail
FAILED=()
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-amd64 arm64}"
conf() { grep "^$1=" lists/apptainer.txt | cut -d= -f2; }

if [ $# -gt 0 ]; then
  DISTROS=("$@")
else
  mapfile -t DISTROS < <(grep -v '^\s*#' lists/distros.txt | grep -v '^\s*$')
fi

mkdir -p vendor/apptainer
for image in "${DISTROS[@]}"; do
  id="${image%%:*}"; version="${image#*:}"
  for arch in $ARCHS; do
    key="${id}-${version}-${arch}"
    echo
    echo "=== apptainer bundle ${key} ==="
    if [ -f "vendor/apptainer/${key}/.complete" ] && [ "${FORCE:-0}" != 1 ]; then
      echo "already done: skipped (FORCE=1 to rebuild it)"
      continue
    fi
    docker pull --quiet --platform "linux/${arch}" "$image" >/dev/null
    docker run --rm --platform "linux/${arch}" \
      -e APPTAINER_VERSION="$(conf version)" -e APPTAINER_SHA256="$(conf sha256)" -e GO_VERSION="$(conf go_version)" \
      -e OUT_DIR="/out/${key}" -e PACKAGES_LIST=/lists/apptainer-packages.txt \
      -v "${ROOT}/lists:/lists:ro" \
      -e EXPECTED_ID="$id" -e EXPECTED_VERSION="$version" -e EXPECTED_ARCH="$arch" \
      -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
      -v "${ROOT}/scripts/lib/apptainer-bundle-inner.sh:/apptainer-bundle-inner.sh:ro" \
      -v "${ROOT}/vendor/apptainer:/out" \
      "$image" bash /apptainer-bundle-inner.sh
    [ -f "vendor/apptainer/${key}/.complete" ] || { echo "ERROR: bundle ${key} failed, going on with the others" >&2; FAILED+=("${key}"); }
  done
done

echo
echo "=== apptainer bundles ==="
for dir in vendor/apptainer/*/; do
  [ -f "$dir/.complete" ] && printf '%-24s %s\n' "$(basename "$dir")" "$(du -sh "$dir/apptainer.tar.gz" | cut -f1)"
done
if [ "${#FAILED[@]}" -gt 0 ]; then
  echo
  echo "FAILED bundles: ${FAILED[*]}  (logs in vendor/apptainer/<key>/logs/)"
  exit 1
fi
