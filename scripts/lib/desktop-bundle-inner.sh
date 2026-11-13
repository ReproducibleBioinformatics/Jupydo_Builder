#!/usr/bin/env bash
# Runs INSIDE the official image of a distribution (scripts/make-vendor-desktop.sh):
# downloads the packages of lists/desktop-packages.txt and the complete closure of
# their dependencies (also those this image already has: target images may lack
# them) as an offline apt repository in $OUT_DIR/debs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
mkdir -p "$OUT_DIR/debs" "$OUT_DIR/logs"
LOG="$OUT_DIR/logs"
. /etc/os-release
[ "${ID}-${VERSION_ID}" = "${EXPECTED_ID}-${EXPECTED_VERSION}" ] \
  || { echo "ERROR: this image is ${ID}-${VERSION_ID}, expected ${EXPECTED_ID}-${EXPECTED_VERSION}" >&2; exit 1; }
[ "$(dpkg --print-architecture)" = "$EXPECTED_ARCH" ] || { echo "ERROR: wrong architecture" >&2; exit 1; }

apt-get update > "$LOG/apt-update.log" 2>&1
apt-get install -y --no-install-recommends dpkg-dev > "$LOG/apt-tools.log" 2>&1
read -r -a PKGS <<< "$(sed 's/#.*//' /desktop-packages.txt | tr '\n' ' ')"
# every package must exist in this release
apt-get install -y --no-install-recommends --simulate "${PKGS[@]}" > "$LOG/simulate.log" 2>&1 \
  || { echo "ERROR: these packages cannot be installed on ${ID}-${VERSION_ID}:"; tail -5 "$LOG/simulate.log"; exit 1; }
apt-cache depends --recurse --no-recommends --no-suggests --no-conflicts --no-breaks --no-replaces \
  --no-enhances "${PKGS[@]}" 2>/dev/null | grep -v '^ ' | grep -v '[<>]' | sort -u > /tmp/closure.txt
cd "$OUT_DIR/debs"
# 50 packages per apt-get call (one call per package is very slow under arm64
# emulation); a group that fails is retried one by one, to find the culprit
missing=()
split -l 50 /tmp/closure.txt /tmp/group.
for group in /tmp/group.*; do
  apt-get download $(cat "$group") >> "$LOG/download.log" 2>&1 && continue
  while read -r pkg; do
    ls ./"${pkg}"_*.deb >/dev/null 2>&1 || apt-get download "$pkg" >> "$LOG/download.log" 2>&1 || missing+=("$pkg")
  done < "$group"
done
[ "${#missing[@]}" -eq 0 ] || echo "note: not downloadable (virtual or not in this release): ${missing[*]}" | tee -a "$LOG/download.log"
dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9n > Packages.gz
sha256sum ./*.deb > SHA256SUMS
cd /
printf '%s\n' "${PKGS[@]}" > "$OUT_DIR/packages.txt"
{ echo "packages ${PKGS[*]}"; echo "closure $(wc -l < /tmp/closure.txt)"
  echo "tigervnc $(apt-cache policy tigervnc-standalone-server | awk '/Candidate/ {print $2}')"
  echo "made $(date -u +%Y-%m-%dT%H:%M:%SZ)"; } > "$OUT_DIR/manifest.txt"
chown -R "${HOST_UID}:${HOST_GID}" "$OUT_DIR"
echo "Desktop: $(ls "$OUT_DIR/debs"/*.deb | wc -l) packages (TigerVNC $(grep '^tigervnc ' "$OUT_DIR/manifest.txt" | cut -d' ' -f2))"
