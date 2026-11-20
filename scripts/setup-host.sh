#!/usr/bin/env bash
# Prepares this machine to use the JupyDo builder (make-vendor-*, build-image.sh,
# test-all.sh). Independent from JupyDo: run it on any machine that builds images.
# Every step checks first: it can be run again at any time.
#   1. Docker present and running
#   2. QEMU emulation (images and bundles of the other architecture): the same QEMU
#      on every machine, registered at every boot with the "F" and "C" flags (sudo
#      works in emulated containers); same service as JupyDo's first_start.sh
#   3. AppArmor profile of the Apptainer module (scripts/load-apparmor-profile.sh)
# Usage (from the builder folder):  sudo scripts/setup-host.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "ERROR: run it with sudo" >&2; exit 1; }

echo "== 1. Docker"
command -v docker >/dev/null || { echo "ERROR: Docker is not installed" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running" >&2; exit 1; }
echo "Docker $(docker version --format '{{.Server.Version}}'): OK"

echo "== 2. QEMU emulation (the other architecture), registered at every boot"
# Always the same QEMU, on every machine: the static one of this pinned image (the
# distributions' QEMU crashes on some programs, e.g. Ubuntu 24.04's 8.2). Registered
# with the flags F (works inside containers) and C (sudo works in emulated containers)
# by a systemd service, at every boot, in place of any QEMU the system registers.
QEMU_IMAGE="tonistiigi/binfmt@sha256:400a4873b838d1b89194d982c45e5fb3cda4593fbfd7e08a02e76b03b21166f0"
QEMU_VERSION="10.2.3"
QEMU_DIR=/usr/local/lib/jupydo/qemu
case "$(uname -m)" in
  x86_64) other=aarch64 ;;
  aarch64) other=x86_64 ;;
  *) echo "ERROR: unsupported machine $(uname -m)" >&2; exit 1 ;;
esac
if ! "$QEMU_DIR/qemu-$other" --version 2>/dev/null | grep -q "version ${QEMU_VERSION}"; then
  docker pull -q "$QEMU_IMAGE" >/dev/null
  cid="$(docker create "$QEMU_IMAGE")"
  mkdir -p "$QEMU_DIR"
  docker cp "$cid:/usr/bin/qemu-$other" "$QEMU_DIR/qemu-$other"
  docker rm "$cid" >/dev/null
fi
"$QEMU_DIR/qemu-$other" --version | head -1
install -D -m 755 scripts/lib/qemu-register.sh /usr/local/lib/jupydo/qemu-register.sh
# the service of older versions (the system's QEMU plus the "C" flag): replaced
if [ -f /etc/systemd/system/jupydo-qemu-credentials.service ]; then
  systemctl disable jupydo-qemu-credentials.service >/dev/null 2>&1 || true
  rm -f /etc/systemd/system/jupydo-qemu-credentials.service /usr/local/lib/jupydo/qemu-binfmt-credentials.sh
fi
cat > /etc/systemd/system/jupydo-qemu.service <<'EOF_UNIT'
[Unit]
Description=JupyDo: QEMU emulator for the other architecture (flags F and C)
After=systemd-binfmt.service binfmt-support.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/jupydo/qemu-register.sh

[Install]
WantedBy=multi-user.target
EOF_UNIT
systemctl daemon-reload
systemctl enable jupydo-qemu.service >/dev/null 2>&1
systemctl restart jupydo-qemu.service
echo "registered: $(sed -n 's/^interpreter //p' "/proc/sys/fs/binfmt_misc/qemu-$other"), flags $(sed -n 's/^flags: //p' "/proc/sys/fs/binfmt_misc/qemu-$other")"
docker run --rm --platform "linux/$( [ "$other" = aarch64 ] && echo arm64 || echo amd64)" alpine:3.20 uname -m

echo "== 3. AppArmor profile of the Apptainer module"
scripts/load-apparmor-profile.sh

echo
echo "This machine is ready for the JupyDo builder."
