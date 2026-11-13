#!/usr/bin/env bash
# Runs INSIDE an official distro image (ubuntu:XX.YY, debian:NN), as root.
# Builds one offline apt repository for that distro + architecture:
#   1. resolves the package lists (alternatives "a|b", optional "?pkg", and the
#      exceptions of lists/distro-exceptions.txt for this distribution);
#   2. downloads the COMPLETE dependency closure (see below);
#   3. writes the repository index and the metadata.
# Inputs (environment): LISTS_DIR (lists/), OUT_DIR (output folder),
#                       EXPECTED_ID, EXPECTED_VERSION, EXPECTED_ARCH (sanity check),
#                       HOST_UID/HOST_GID (optional: owner of the output files).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release
ARCH="$(dpkg --print-architecture)"
if [ "$ID" != "$EXPECTED_ID" ] || [ "$VERSION_ID" != "$EXPECTED_VERSION" ] || [ "$ARCH" != "$EXPECTED_ARCH" ]; then
  echo "ERROR: expected ${EXPECTED_ID} ${EXPECTED_VERSION} ${EXPECTED_ARCH}, found ${ID} ${VERSION_ID} ${ARCH}" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/debs" "$OUT_DIR/lists" "$OUT_DIR/logs"
# The packages of this official image, before anything is added: they are downloaded
# too (only downloaded: what gets installed is always the lists'). An image OLDER than
# this bundle can then be brought forward where needed: e.g. util-linux requires its
# own exact libuuid1, so libuuid1 cannot be updated for uuid-dev unless util-linux can
# be updated too, and util-linux is not a dependency of anything in the lists.
dpkg-query -W -f '${db:Status-Abbrev} ${Package}\n' | awk '$1 == "ii" {print $2}' | sort -u > "$OUT_DIR/lists/image-packages.txt"
apt-get update > "$OUT_DIR/logs/apt-update.log" 2>&1

# Every package name the repositories offer, read once (one apt-cache call per
# package reloads the whole index: very slow under QEMU emulation)
AVAILABLE="$(mktemp)"
apt-cache dumpavail | sed -n 's/^Package: //p' | sort -u > "$AVAILABLE"
available() { grep -qxF "$1" "$AVAILABLE"; }

# lists/distro-exceptions.txt: on this distribution a package of the lists is
# replaced by another one, or skipped ("-")
DISTRO="${ID}-${VERSION_ID}"
exception_for() {  # $1 = package name -> its replacement here ("" = none)
  [ -f "$LISTS_DIR/distro-exceptions.txt" ] || return 0
  awk -v d="$DISTRO" -v p="$1" '$1 !~ /^#/ && $1 == d && $2 == p {print $3; exit}' "$LISTS_DIR/distro-exceptions.txt"
}

# ---- 1. resolve every list (apt-base.txt, apt-<module>.txt) for this release
ALL=()
MISSING=()
for list in "$LISTS_DIR"/apt-*.txt; do
  group="$(basename "$list" .txt)"; group="${group#apt-}"
  : > "$OUT_DIR/lists/$group.txt"
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"
    [ -n "$line" ] || continue
    optional=""
    if [ "${line:0:1}" = "?" ]; then optional=1; line="${line:1}"; fi
    chosen=""
    IFS='|' read -r -a alternatives <<< "$line"
    skip=""
    for i in "${!alternatives[@]}"; do
      replacement="$(exception_for "${alternatives[$i]}")"
      if [ "$replacement" = "-" ]; then skip=1
      elif [ -n "$replacement" ]; then alternatives[$i]="$replacement"; fi
    done
    if [ -n "$skip" ]; then
      echo "exception for ${DISTRO}: $line skipped" | tee -a "$OUT_DIR/logs/skipped.log"
      continue
    fi
    for name in "${alternatives[@]}"; do
      if available "$name"; then chosen="$name"; break; fi
    done
    if [ -n "$chosen" ]; then
      echo "$chosen" >> "$OUT_DIR/lists/$group.txt"
      ALL+=("$chosen")
    elif [ -n "$optional" ]; then
      echo "WARNING: optional package not in ${ID} ${VERSION_ID}: $line (skipped)" | tee -a "$OUT_DIR/logs/skipped.log"
    else
      MISSING+=("$group: $line")
    fi
  done < "$list"
done
if [ "${#MISSING[@]}" -gt 0 ]; then
  echo "ERROR: packages not available in ${ID} ${VERSION_ID} ${ARCH}:" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  exit 1
fi

# ---- 2. download the complete closure
# apt is told that NOTHING is installed (empty dpkg status), so its resolver
# downloads every dependency, also those already present in this container.
# Otherwise a final image with slightly different versions of a library could
# not satisfy the dependency offline (seen with liblzma5, libssl3, perl-base).
EMPTY_STATUS="$(mktemp)"
ARCHIVES="$(mktemp -d)"
mkdir -p "$ARCHIVES/partial"
mapfile -t IMAGE_PKGS < "$OUT_DIR/lists/image-packages.txt"
apt-get install -y --download-only --no-install-recommends \
  -o Dir::State::status="$EMPTY_STATUS" \
  -o Dir::Cache::archives="$ARCHIVES" \
  "${ALL[@]}" "${IMAGE_PKGS[@]}" > "$OUT_DIR/logs/apt-download.log" 2>&1 \
  || { tail -30 "$OUT_DIR/logs/apt-download.log" >&2; exit 1; }
mv "$ARCHIVES"/*.deb "$OUT_DIR/debs/"

# ---- 3. repository index + metadata
apt-get install -y --no-install-recommends dpkg-dev > "$OUT_DIR/logs/dpkg-dev.log" 2>&1
cd "$OUT_DIR/debs"
dpkg-scanpackages . /dev/null 2> "$OUT_DIR/logs/dpkg-scanpackages.log" | gzip -9n > Packages.gz
sha256sum ./*.deb > SHA256SUMS
for deb in ./*.deb; do
  printf '%s\t%s\t%s\n' "$(dpkg-deb -f "$deb" Package)" "$(dpkg-deb -f "$deb" Version)" "$(dpkg-deb -f "$deb" Architecture)"
done | sort > "$OUT_DIR/versions.tsv"

{
  echo "distro=${ID}"
  echo "version=${VERSION_ID}"
  echo "codename=${VERSION_CODENAME:-unknown}"
  echo "architecture=${ARCH}"
  echo "debs=$(ls ./*.deb | wc -l)"
  echo "image_packages=$(wc -l < "$OUT_DIR/lists/image-packages.txt")"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT_DIR/platform.txt"
touch "$OUT_DIR/.complete"
if [ -n "${HOST_UID:-}" ]; then chown -R "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$OUT_DIR"; fi
echo "OK ${ID}-${VERSION_ID}-${ARCH}: $(ls ./*.deb | wc -l) packages, $(du -sh . | cut -f1)"
