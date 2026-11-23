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

# Never remove anything the image has (e.g. its compilers), and prefer the versions it
# already has: the bundle only adds what is missing. If the module really needs newer
# versions, a second try upgrades them, still without removing anything (else it stops).
bundle_install() {   # bundle_install <apt dir> <package>...
  local dir="$1"; shift
  mkdir -p "$dir/prefs.d"
  printf 'Package: *\nPin: origin ""\nPin-Priority: 50\n' > "$dir/prefs.d/prefer-installed.pref"
  apt-get "${APT_ONLY_BUNDLE[@]}" -o Dir::Etc::preferencesparts="$dir/prefs.d" \
      install -y --no-install-recommends --no-remove "$@" \
  || { echo "[jupydo] the module needs newer versions of some packages: upgrading them (nothing removed)" >&2
       apt-get "${APT_ONLY_BUNDLE[@]}" install -y --no-install-recommends --no-remove "$@"; } \
  || { echo "[jupydo] trying the distribution's archive too (the image's own apt sources, online)" >&2
       local od="$dir/online.d" before="$dir/before-online.txt"
       mkdir -p "$od" "$dir/online-state/partial"
       cp -a /etc/apt/sources.list.d/. "$od"/ 2>/dev/null || true
       [ -f /etc/apt/sources.list ] && cp /etc/apt/sources.list "$od/image.list"
       cp "$dir/sources.list" "$od/jupydo-bundles.list"
       local ONLINE=(-o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts="$od"
                     -o Dir::State::Lists="$dir/online-state" -o APT::Default-Release=)
       dpkg-query -W -f '${db:Status-Abbrev} ${Package}:${Architecture} ${Version}\n' | awk '$1 == "ii" {print $2, $3}' | sort > "$before"
       apt-get "${ONLINE[@]}" update \
       && apt-get "${ONLINE[@]}" install -y --no-install-recommends --no-remove "$@" \
       && dpkg-query -W -f '${db:Status-Abbrev} ${Package}:${Architecture} ${Version}\n' | awk '$1 == "ii" {print $2, $3}' \
            | sort | comm -13 "$before" - >> /opt/jupydo/apt-online.txt; }
}

mkdir -p /tmp/desktop-apt/state/partial
echo "deb [trusted=yes] file:${BUNDLE}/debs ./" > /tmp/desktop-apt/sources.list
# the base apt bundle (same distribution), to upgrade instead of remove (see the Dockerfile)
[ -d /tmp/vendor-apt/debs ] && echo "deb [trusted=yes] file:/tmp/vendor-apt/debs ./" >> /tmp/desktop-apt/sources.list
APT_ONLY_BUNDLE=(-o Dir::Etc::sourcelist=/tmp/desktop-apt/sources.list -o Dir::Etc::sourceparts=-
                 -o Dir::State::Lists=/tmp/desktop-apt/state -o APT::Get::List-Cleanup=0
                 -o APT::Default-Release=)   # some images set it (e.g. "testing"): unknown to the bundle
apt-get "${APT_ONLY_BUNDLE[@]}" update
# exit 100: it cannot be added without removing packages of the image (see the Dockerfile)
bundle_install /tmp/desktop-apt $(cat "${BUNDLE}/packages.txt") || exit 100
rm -rf /tmp/desktop-apt
command -v vncserver >/dev/null || { echo "ERROR: vncserver not found after the installation" >&2; exit 1; }
# vncserver is a Perl script, and Perl stops when a folder of PERL5LIB/PERLLIB cannot be
# read (some images point them into another user's home): vncserver gets only the
# readable ones (the desktop session inherits them; the others were unusable anyway)
VNC="$(command -v vncserver)"
if [ ! -e "${VNC}.jupydo-real" ]; then
  dpkg-divert --quiet --local --rename --divert "${VNC}.jupydo-real" --add "$VNC" 2>/dev/null \
    || mv "$VNC" "${VNC}.jupydo-real"
  cat > "$VNC" <<EOF_VNC
#!/bin/sh
# JupyDo: TigerVNC's vncserver (${VNC}.jupydo-real) with only the readable Perl library folders
for var in PERL5LIB PERLLIB; do
  eval "val=\\\${\$var:-}"
  [ -n "\$val" ] || continue
  keep=""
  for d in \$(echo "\$val" | tr ':' ' '); do
    [ -r "\$d" ] && keep="\${keep:+\$keep:}\$d"
  done
  if [ -n "\$keep" ]; then export "\$var=\$keep"; else unset "\$var"; fi
done
exec "${VNC}.jupydo-real" "\$@"
EOF_VNC
  chmod 755 "$VNC"
fi

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
# D-Bus (the XFCE session) stops when the machine has no id: some images do not have one
[ -s /etc/machine-id ] || dbus-uuidgen --ensure=/etc/machine-id 2>/dev/null \
  || tr -d '-' < /proc/sys/kernel/random/uuid > /etc/machine-id
[ -e /var/lib/dbus/machine-id ] || { mkdir -p /var/lib/dbus && ln -s /etc/machine-id /var/lib/dbus/machine-id; }
# the user's files on the desktop
ln -sfn /sharedFolder /home/jovyan/Desktop/sharedFolder
echo "[install-desktop] XFCE + $(vncserver -version 2>&1 | grep -m1 -i vnc || echo TigerVNC)"
