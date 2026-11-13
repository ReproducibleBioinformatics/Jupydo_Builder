#!/usr/bin/env bash
# Runs INSIDE the official image of a distribution (scripts/make-vendor-rstudio.sh):
# downloads the RStudio Server package and the complete closure of its dependencies
# (every package, also those this image already has: target images may lack them)
# as an offline apt repository in $OUT_DIR/debs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$OUT_DIR/debs" "$OUT_DIR/logs"
LOG="$OUT_DIR/logs"
. /etc/os-release
[ "${ID}-${VERSION_ID}" = "${EXPECTED_ID}-${EXPECTED_VERSION}" ] \
  || { echo "ERROR: this image is ${ID}-${VERSION_ID}, expected ${EXPECTED_ID}-${EXPECTED_VERSION}" >&2; exit 1; }
[ "$(dpkg --print-architecture)" = "$EXPECTED_ARCH" ] || { echo "ERROR: wrong architecture" >&2; exit 1; }

apt-get update > "$LOG/apt-update.log" 2>&1
apt-get install -y --no-install-recommends curl ca-certificates dpkg-dev > "$LOG/apt-tools.log" 2>&1

echo "downloading $RSTUDIO_URL"
curl -fsSL -o /tmp/rstudio-server.deb "$RSTUDIO_URL"
SHA="$(sha256sum /tmp/rstudio-server.deb | cut -d' ' -f1)"
VERSION="$(dpkg-deb -f /tmp/rstudio-server.deb Version)"
cp /tmp/rstudio-server.deb "$OUT_DIR/debs/rstudio-server_${VERSION}_${EXPECTED_ARCH}.deb"

# dependencies of the package (all alternatives), then their full recursive closure
dpkg-deb -f /tmp/rstudio-server.deb Depends | tr ',|' '\n\n' | sed 's/(.*)//; s/:any//; s/ //g' | awk 'NF' \
  | sort -u > /tmp/direct.txt
apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces \
  --no-enhances $(cat /tmp/direct.txt) 2>/dev/null | grep -v '^ ' | grep -v '[<>]' | sort -u > /tmp/closure.txt
cd "$OUT_DIR/debs"
missing=()
while read -r pkg; do
  apt-get download "$pkg" >> "$LOG/download.log" 2>&1 || missing+=("$pkg")
done < /tmp/closure.txt
[ "${#missing[@]}" -eq 0 ] || echo "note: not downloadable (virtual or not in this release): ${missing[*]}" | tee -a "$LOG/download.log"
dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9n > Packages.gz
sha256sum ./*.deb > SHA256SUMS
cd /
echo rstudio-server > "$OUT_DIR/packages.txt"
{ echo "url ${RSTUDIO_URL}"; echo "version ${VERSION}"; echo "sha256 ${SHA}"
  echo "dependencies $(wc -l < /tmp/closure.txt)"; echo "made $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$OUT_DIR/manifest.txt"
chown -R "${HOST_UID}:${HOST_GID}" "$OUT_DIR"
echo "RStudio Server ${VERSION}: $(ls "$OUT_DIR/debs"/*.deb | wc -l) packages"
