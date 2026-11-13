#!/usr/bin/env bash
# Saves the base used to convert BusyBox + conda images (lists/convert-bases.txt)
# in vendor/bases/<distro>-<version>-<arch>/: image.tar (docker save, tagged
# jupydo-base/<distro>-<version>:<arch>), its digest and checksum in manifest.txt.
# The build loads it from there: no network needed afterwards.
#
# Usage (from the builder folder):
#   scripts/make-vendor-bases.sh                 amd64 + arm64
#   ARCHS=amd64 scripts/make-vendor-bases.sh     only amd64
#   FORCE=1 scripts/make-vendor-bases.sh         save again bases already done
set -euo pipefail
cd "$(dirname "$0")/.."
ARCHS="${ARCHS:-amd64 arm64}"
mapfile -t BASES < <(grep -v '^\s*#' lists/convert-bases.txt | grep -v '^\s*$')
for image in "${BASES[@]}"; do
  id="${image%%:*}"; version="${image#*:}"
  for arch in $ARCHS; do
    key="${id}-${version}-${arch}"
    dir="vendor/bases/${key}"
    echo "=== base ${key} ==="
    if [ -f "${dir}/.complete" ] && [ "${FORCE:-0}" != 1 ]; then
      echo "already done: skipped (FORCE=1 to save it again)"; continue
    fi
    [ -f "vendor/apt/${key}/.complete" ] || { echo "ERROR: no apt bundle vendor/apt/${key}: make it first" >&2; exit 1; }
    rm -rf "$dir"; mkdir -p "$dir"
    docker pull --quiet --platform "linux/${arch}" "$image" >/dev/null
    # the digest of the official image (not of the local copy tagged below)
    digest="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" \
              | grep "^${id}@\|^docker.io/library/${id}@\|^library/${id}@" | head -1)"
    local_tag="jupydo-base/${id}-${version}:${arch}"
    docker tag "$image" "$local_tag"
    # only this architecture (the same name holds both after two pulls)
    docker save --platform "linux/${arch}" -o "${dir}/image.tar" "$local_tag" 2>/dev/null \
      || docker save -o "${dir}/image.tar" "$local_tag"
    # check: loaded back, it must be this architecture
    docker rmi "$local_tag" >/dev/null
    docker load --quiet -i "${dir}/image.tar" >/dev/null
    got="$(docker image inspect --platform "linux/${arch}" --format '{{.Architecture}}' "$local_tag" 2>/dev/null \
           || docker image inspect --format '{{.Architecture}}' "$local_tag")"
    [ "$got" = "$arch" ] || { echo "ERROR: ${dir}/image.tar is ${got:-?}, not ${arch}" >&2; rm -rf "$dir"; exit 1; }
    { echo "image ${image}"; echo "digest ${digest}"; echo "arch ${arch}"; echo "tag ${local_tag}"
      echo "saved $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "sha256 $(sha256sum "${dir}/image.tar" | cut -d' ' -f1)"; } > "${dir}/manifest.txt"
    touch "${dir}/.complete"
    echo "saved ${dir}/image.tar (${digest})"
  done
done
