#!/usr/bin/env bash
# Prepares this machine to use the JupyDo builder (make-vendor-*, build-image.sh,
# test-all.sh). Independent from JupyDo: run it on any machine that builds images.
# Every step checks first: it can be run again at any time.
#   1. Docker present and running
#   2. QEMU emulation (images and bundles of the other architecture)
#   3. QEMU registered with the "C" flag at every boot: sudo works in emulated
#      containers (same service JupyDo's first_start.sh installs: no duplicates)
#   4. AppArmor profile of the Apptainer module (scripts/load-apparmor-profile.sh)
# Usage (from the builder folder):  sudo scripts/setup-host.sh
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "ERROR: run it with sudo" >&2; exit 1; }

echo "== 1. Docker"
command -v docker >/dev/null || { echo "ERROR: Docker is not installed" >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "ERROR: Docker is not running" >&2; exit 1; }
echo "Docker $(docker version --format '{{.Server.Version}}'): OK"

echo "== 2. QEMU emulation"
if dpkg -s qemu-user-static >/dev/null 2>&1; then
  echo "qemu-user-static already installed"
else
  apt-get update -qq && apt-get install -y -qq qemu-user-static binfmt-support
  echo "qemu-user-static installed"
fi

echo "== 3. QEMU with the \"C\" flag (sudo in emulated containers), at every boot"
install -D -m 755 scripts/lib/qemu-binfmt-credentials.sh /usr/local/lib/jupydo/qemu-binfmt-credentials.sh
cat > /etc/systemd/system/jupydo-qemu-credentials.service <<'EOF_UNIT'
[Unit]
Description=JupyDo: QEMU emulators with the credentials flag (sudo in emulated containers)
After=systemd-binfmt.service binfmt-support.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/lib/jupydo/qemu-binfmt-credentials.sh

[Install]
WantedBy=multi-user.target
EOF_UNIT
systemctl daemon-reload
systemctl enable jupydo-qemu-credentials.service >/dev/null 2>&1
systemctl restart jupydo-qemu-credentials.service
echo "flags: $(sed -n 's/^flags: //p' /proc/sys/fs/binfmt_misc/qemu-aarch64 2>/dev/null || echo '-')"

echo "== 4. AppArmor profile of the Apptainer module"
scripts/load-apparmor-profile.sh

echo
echo "This machine is ready for the JupyDo builder."
