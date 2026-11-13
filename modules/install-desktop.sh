#!/usr/bin/env bash
# Desktop module, run by the Dockerfile as root when the image is built with it.
# Installs, offline, from the bundle in $1 (vendor/desktop/<key>):
#   - an XFCE desktop and TigerVNC, with all their system packages (debs/);
#   - the JupyterLab extension that adds "Desktop" to the launcher and starts the
#     desktop as the user, shown in a browser tab (wheels/), into JupyDo's Python;
#   - a "sharedFolder" shortcut on the desktop (the user's files, as in JupyterLab).
set -euo pipefail
BUNDLE="${1:?usage: install-desktop.sh <bundle folder>}"
export DEBIAN_FRONTEND=noninteractive

mkdir -p /tmp/desktop-apt/state/partial
echo "deb [trusted=yes] file:${BUNDLE}/debs ./" > /tmp/desktop-apt/sources.list
APT_ONLY_BUNDLE=(-o Dir::Etc::sourcelist=/tmp/desktop-apt/sources.list -o Dir::Etc::sourceparts=-
                 -o Dir::State::Lists=/tmp/desktop-apt/state -o APT::Get::List-Cleanup=0
                 -o APT::Default-Release=)   # some images set it (e.g. "testing"): unknown to the bundle
apt-get "${APT_ONLY_BUNDLE[@]}" update
apt-get "${APT_ONLY_BUNDLE[@]}" install -y --no-install-recommends $(cat "${BUNDLE}/packages.txt")
rm -rf /tmp/desktop-apt
command -v vncserver >/dev/null || { echo "ERROR: vncserver not found after the installation" >&2; exit 1; }

# the launcher icon and the proxy, into JupyDo's Python (never the image's)
/opt/python4Jup/bin/python3 -m pip install --quiet --disable-pip-version-check --no-index \
  --no-cache-dir --root-user-action=ignore --find-links "${BUNDLE}/wheels" \
  jupyter-remote-desktop-proxy jupyter-server-proxy

# The home belongs to root and the user can write only inside the folders it already
# has (they are given to the user at start): create here the ones the desktop needs,
# TigerVNC's (.vnc up to 1.12, .config/tigervnc from 1.13) and XFCE's settings and caches
mkdir -p /home/jovyan/.vnc /home/jovyan/.config/tigervnc /home/jovyan/.cache /home/jovyan/.local/share \
         /home/jovyan/.dbus/session-bus /home/jovyan/Desktop
# The X and ICE keys (and the lock files xauth makes next to them) cannot be created
# in the home itself: they go in ~/.cache, set for the desktop started by JupyterLab
CONF=/opt/python4Jup/etc/jupyter/jupyter_server_config.py
mkdir -p "$(dirname "$CONF")"
sed -i '/# >>> JupyDo Desktop/,/# <<< JupyDo Desktop/d' "$CONF" 2>/dev/null || true
printf '%s\n' "# >>> JupyDo Desktop" "import os" \
  "os.environ.setdefault('XAUTHORITY', os.path.join(os.path.expanduser('~'), '.cache', 'Xauthority'))" \
  "os.environ.setdefault('ICEAUTHORITY', os.path.join(os.path.expanduser('~'), '.cache', 'ICEauthority'))" \
  "# <<< JupyDo Desktop" >> "$CONF"
# the user's files on the desktop
ln -sfn /sharedFolder /home/jovyan/Desktop/sharedFolder
echo "[install-desktop] XFCE + $(vncserver -version 2>&1 | grep -m1 -i vnc || echo TigerVNC)"
