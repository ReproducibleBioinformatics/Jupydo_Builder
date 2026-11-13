#!/usr/bin/env bash
# Runs INSIDE an official distro image (ubuntu:XX.YY, debian:NN), as root.
# Builds Apptainer from its official source release, unprivileged mode only
# (--without-suid), into /opt/apptainer, together with the helper programs the
# official .deb/.rpm ship (squashfuse, fuse-overlayfs, gocryptfs, fuse2fs, PRoot,
# mksquashfs/unsquashfs), using Apptainer's own scripts for them. Everything is
# compiled against THIS distribution's libraries (e.g. libfuse3-3 vs libfuse3-4).
# The bundle is self-contained: it also carries, as a small offline apt repository
# (debs/), the system packages Apptainer needs at run time (PACKAGES_LIST), with
# their complete dependency closure. The base apt bundle is never changed for it.
# Inputs (environment): APPTAINER_VERSION, APPTAINER_SHA256, GO_VERSION, OUT_DIR,
#                       PACKAGES_LIST, EXPECTED_ID, EXPECTED_VERSION, EXPECTED_ARCH,
#                       HOST_UID/HOST_GID.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# Go programs can hang under QEMU emulation (arm64 on amd64) because of Go's signal-
# based asynchronous preemption: off for the whole build (Go tools and the programs
# the build runs, e.g. apptainer itself to generate its bash completion).
export GODEBUG=asyncpreemptoff=1
PREFIX=/opt/apptainer

. /etc/os-release
ARCH="$(dpkg --print-architecture)"
if [ "$ID" != "$EXPECTED_ID" ] || [ "$VERSION_ID" != "$EXPECTED_VERSION" ] || [ "$ARCH" != "$EXPECTED_ARCH" ]; then
  echo "ERROR: expected ${EXPECTED_ID} ${EXPECTED_VERSION} ${EXPECTED_ARCH}, found ${ID} ${VERSION_ID} ${ARCH}" >&2
  exit 1
fi
rm -rf "$OUT_DIR" "$PREFIX"
mkdir -p "$OUT_DIR/logs"
LOG="$OUT_DIR/logs"
step() { echo "[$(date +%H:%M:%S)] $*"; }

# ---- build dependencies (from the distribution, only in this build container)
step "build dependencies"
apt-get update > "$LOG/apt-update.log" 2>&1
apt-get install -y --no-install-recommends \
  build-essential pkg-config git curl wget ca-certificates file tzdata cryptsetup uidmap fakeroot \
  libseccomp-dev libtalloc-dev libattr1-dev libprotobuf-c-dev \
  autoconf automake libtool libfuse3-dev zlib1g-dev liblzo2-dev liblz4-dev liblzma-dev libzstd-dev \
  > "$LOG/apt-install.log" 2>&1 || { tail -20 "$LOG/apt-install.log" >&2; exit 1; }
# on arm64 Go links with the gold linker (-fuse-ld=gold); Ubuntu 26.04+ ships it in
# its own package (it used to be part of binutils)
if apt-cache show binutils-gold >/dev/null 2>&1; then
  apt-get install -y --no-install-recommends binutils-gold >> "$LOG/apt-install.log" 2>&1
fi

# ---- Go (official archive, checked against the checksum Go publishes next to it)
step "Go ${GO_VERSION}"
GO_TGZ="go${GO_VERSION}.linux-${ARCH}.tar.gz"
curl -fsSL -o "/tmp/${GO_TGZ}" "https://dl.google.com/go/${GO_TGZ}"
GO_SHA="$(curl -fsSL "https://dl.google.com/go/${GO_TGZ}.sha256" | awk '{print $1}')"
echo "${GO_SHA}  /tmp/${GO_TGZ}" | sha256sum -c --status || { echo "ERROR: Go checksum mismatch" >&2; exit 1; }
tar -C /usr/local -xzf "/tmp/${GO_TGZ}"
export PATH="/usr/local/go/bin:$PATH"

# ---- Apptainer source (official release, checksum from lists/apptainer.txt)
step "Apptainer ${APPTAINER_VERSION} source"
SRC_TGZ=/tmp/apptainer.tar.gz
curl -fsSL -o "$SRC_TGZ" \
  "https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer-${APPTAINER_VERSION}.tar.gz"
echo "${APPTAINER_SHA256}  ${SRC_TGZ}" | sha256sum -c --status || { echo "ERROR: Apptainer source checksum mismatch" >&2; exit 1; }
mkdir -p /tmp/src && tar -xzf "$SRC_TGZ" -C /tmp/src
SRC="/tmp/src/apptainer-${APPTAINER_VERSION}"

step "compile Apptainer"
cd "$SRC"
./mconfig --prefix="$PREFIX" --without-suid --without-libsubid > "$LOG/mconfig.log" 2>&1 \
  || { tail -30 "$LOG/mconfig.log" >&2; exit 1; }
make -C builddir -j"$(nproc)" > "$LOG/make.log" 2>&1 || { tail -30 "$LOG/make.log" >&2; exit 1; }
make -C builddir install > "$LOG/make-install.log" 2>&1

# ---- helper programs, exactly as the official packages build them
step "helper programs (squashfuse, fuse-overlayfs, gocryptfs, ...)"
mkdir -p /tmp/deps-src /tmp/deps-build
./scripts/download-dependencies /tmp/deps-src > "$LOG/deps-download.log" 2>&1 \
  || { tail -30 "$LOG/deps-download.log" >&2; exit 1; }
(cd /tmp/deps-build && "$SRC/scripts/compile-dependencies" /tmp/deps-src) > "$LOG/deps-compile.log" 2>&1 \
  || { tail -30 "$LOG/deps-compile.log" >&2; exit 1; }
(cd /tmp/deps-build && "$SRC/scripts/install-dependencies" "$PREFIX/libexec") > "$LOG/deps-install.log" 2>&1 \
  || { tail -30 "$LOG/deps-install.log" >&2; exit 1; }

# unprivileged only: no setuid starter (also not built, --without-suid)
sed -i 's/^allow setuid = yes/allow setuid = no/' "$PREFIX/etc/apptainer/apptainer.conf"

# ---- self-check + the run-time libraries the programs really use
step "check"
"$PREFIX/bin/apptainer" --version
ls "$PREFIX/libexec/apptainer/bin" > "$OUT_DIR/helpers.txt"
for h in squashfuse_ll fuse-overlayfs gocryptfs; do
  grep -qx "$h" "$OUT_DIR/helpers.txt" || { echo "ERROR: helper $h missing" >&2; exit 1; }
done
find "$PREFIX" -type f -perm -u+x -exec sh -c 'file -b "$1" | grep -q ELF && echo "$1"' _ {} \; > /tmp/elf.txt
# one file at a time: static programs (gocryptfs, Go parts) make ldd fail, that is fine
: > /tmp/ldd.txt
while read -r f; do ldd "$f" >> /tmp/ldd.txt 2>/dev/null || true; done < /tmp/elf.txt
if grep -q "not found" /tmp/ldd.txt; then
  echo "ERROR: unresolved libraries:" >&2; grep "not found" /tmp/ldd.txt | sort -u >&2; exit 1
fi
awk '/=> \//{print $3}' /tmp/ldd.txt | sort -u > /tmp/libs.txt
# the package of each library (merged /usr: try the path as given and the real path)
while read -r lib; do
  dpkg -S "$lib" 2>/dev/null || dpkg -S "$(readlink -f "$lib")" 2>/dev/null || true
done < /tmp/libs.txt | cut -d: -f1 | sort -u > "$OUT_DIR/runtime-packages.txt"
cp /tmp/ldd.txt "$LOG/ldd.txt"

# ---- run-time system packages: offline apt repository inside the bundle
step "run-time packages"
apt-cache dumpavail | sed -n 's/^Package: //p' | sort -u > /tmp/available
RUNTIME=()
while IFS= read -r line; do
  line="${line%%#*}"; line="$(echo "$line" | xargs)"
  [ -n "$line" ] || continue
  optional=""; if [ "${line:0:1}" = "?" ]; then optional=1; line="${line:1}"; fi
  chosen=""
  IFS='|' read -r -a alternatives <<< "$line"
  for name in "${alternatives[@]}"; do grep -qxF "$name" /tmp/available && { chosen="$name"; break; }; done
  if [ -n "$chosen" ]; then RUNTIME+=("$chosen")
  elif [ -z "$optional" ]; then echo "ERROR: run-time package not available: $line" >&2; exit 1; fi
done < "$PACKAGES_LIST"
printf '%s\n' "${RUNTIME[@]}" > "$OUT_DIR/packages.txt"
# every library the programs use must come from a listed package or its dependencies
mkdir -p "$OUT_DIR/debs" /tmp/runtime-archives/partial
EMPTY_STATUS="$(mktemp)"
apt-get install -y --download-only --no-install-recommends \
  -o Dir::State::status="$EMPTY_STATUS" -o Dir::Cache::archives=/tmp/runtime-archives \
  "${RUNTIME[@]}" > "$LOG/runtime-download.log" 2>&1 || { tail -20 "$LOG/runtime-download.log" >&2; exit 1; }
mv /tmp/runtime-archives/*.deb "$OUT_DIR/debs/"
for pkg in $(cat "$OUT_DIR/runtime-packages.txt"); do
  ls "$OUT_DIR/debs/${pkg}_"*.deb >/dev/null 2>&1 \
    || { echo "ERROR: ${pkg} (used by Apptainer) is not in the bundle: add it to lists/apptainer-packages.txt" >&2; exit 1; }
done
(cd "$OUT_DIR/debs" && dpkg-scanpackages . /dev/null 2>/dev/null | gzip -9n > Packages.gz && sha256sum ./*.deb > SHA256SUMS)

# ---- pack
tar -czf "$OUT_DIR/apptainer.tar.gz" -C /opt apptainer
(cd "$OUT_DIR" && sha256sum apptainer.tar.gz debs/Packages.gz > SHA256SUMS)
{
  echo "apptainer=${APPTAINER_VERSION}"
  echo "go=${GO_VERSION}"
  echo "distro=${ID}-${VERSION_ID}"
  echo "architecture=${ARCH}"
  echo "helpers=$(tr '\n' ' ' < "$OUT_DIR/helpers.txt")"
  echo "runtime_debs=$(ls "$OUT_DIR"/debs/*.deb | wc -l)"
  echo "dependency_sources=$(ls /tmp/deps-src | tr '\n' ' ')"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT_DIR/manifest.txt"
touch "$OUT_DIR/.complete"
if [ -n "${HOST_UID:-}" ]; then chown -R "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$OUT_DIR"; fi
echo "OK apptainer ${ID}-${VERSION_ID}-${ARCH}: $(du -sh "$OUT_DIR/apptainer.tar.gz" | cut -f1)"
