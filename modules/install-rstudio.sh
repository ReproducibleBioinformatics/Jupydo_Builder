#!/usr/bin/env bash
# RStudio module, run by the Dockerfile as root when the image is built with it.
# Installs, offline, from the self-contained bundle in $1 (vendor/rstudio/<key>):
#   - RStudio Server (open-source edition) and its system packages (debs/);
#   - the JupyterLab extension that adds "RStudio" to the launcher and starts
#     RStudio Server as the user, behind the JupyterLab login (wheels/), into
#     JupyDo's own Python only.
# If the image already has RStudio Server (Rocker, Bioconductor...), it is kept as it is.
# RStudio Server (open source) uses one R: the system or Posit R is preferred to a
# conda one; with no R in the image nothing is fixed, and RStudio uses the R found on
# the PATH when a session starts (e.g. one the user installs later).
set -euo pipefail
BUNDLE="${1:?usage: install-rstudio.sh <bundle folder>}"
export DEBIAN_FRONTEND=noninteractive
RSERVER=/usr/lib/rstudio-server/bin/rserver

if [ -x "$RSERVER" ] || command -v rserver >/dev/null 2>&1; then
  echo "[install-rstudio] the base image already has RStudio Server: kept as it is"
else
  mkdir -p /tmp/rstudio-apt/state/partial
  echo "deb [trusted=yes] file:${BUNDLE}/debs ./" > /tmp/rstudio-apt/sources.list
  APT_ONLY_BUNDLE=(-o Dir::Etc::sourcelist=/tmp/rstudio-apt/sources.list -o Dir::Etc::sourceparts=-
                   -o Dir::State::Lists=/tmp/rstudio-apt/state -o APT::Get::List-Cleanup=0
                   -o APT::Default-Release=)   # some images set it (e.g. "testing"): unknown to the bundle
  apt-get "${APT_ONLY_BUNDLE[@]}" update
  apt-get "${APT_ONLY_BUNDLE[@]}" install -y --no-install-recommends $(cat "${BUNDLE}/packages.txt")
  rm -rf /tmp/rstudio-apt
  # a container has no init system: RStudio is started by JupyterLab, never as a service
  command -v systemctl >/dev/null 2>&1 && systemctl disable rstudio-server >/dev/null 2>&1 || true
fi

# RStudio Server is made for a system service running as its own user; here it is
# started by JupyterLab as the environment's only user. Recent versions (2026) need:
# - logs on the standard error (collected by JupyterLab), not in /var/log/rstudio,
#   where the user cannot write: otherwise every error is lost and it just hangs;
# - its state folder writable and its session RPC key readable by that user (a
#   JupyDo environment has one user, so this exposes nothing to anyone else).
mkdir -p /etc/rstudio /var/lib/rstudio-server
printf '[*]\nlog-level=warn\nlogger-type=stderr\n' > /etc/rstudio/logging.conf
chmod 1777 /var/lib/rstudio-server
[ -f /var/lib/rstudio-server/session-rpc-key ] && chmod 644 /var/lib/rstudio-server/session-rpc-key

# RStudio opens in the same place as JupyterLab: the user's shared folder (data
# and files survive the environment), not the home, which holds only settings.
sed -i '/^session-default-working-dir=/d' /etc/rstudio/rsession.conf 2>/dev/null || true
echo "session-default-working-dir=/sharedFolder" >> /etc/rstudio/rsession.conf
if [ ! -f /etc/rstudio/rstudio-prefs.json ]; then
  printf '{\n  "initial_working_directory": "/sharedFolder"\n}\n' > /etc/rstudio/rstudio-prefs.json
fi

# the launcher icon and the proxy, into JupyDo's Python (never the image's)
/opt/python4Jup/bin/python3 -m pip install --quiet --disable-pip-version-check --no-index \
  --no-cache-dir --root-user-action=ignore \
  --find-links "${BUNDLE}/wheels" jupyter-rsession-proxy

# Which R. RStudio Server (open source) uses one R per server: the launcher icon
# "RStudio" uses the preferred one (system or Posit, then conda), and every other R
# of the image gets its own icon "RStudio (R x.y, <where>)", a separate RStudio with
# its own settings and sessions. With no R in the image nothing is fixed: RStudio
# uses the R found on the PATH when a session starts (e.g. one installed later).
ALL_R=()
for r in /usr/local/bin/R /usr/bin/R /opt/R/*/bin/R /opt/*/bin/R /opt/*/envs/*/bin/R; do
  [ -x "$r" ] || continue
  real="$(readlink -f "$r")"
  for seen in "${ALL_R[@]+"${ALL_R[@]}"}"; do [ "$(readlink -f "$seen")" = "$real" ] && continue 2; done
  ALL_R+=("$r")
done
mkdir -p /etc/rstudio
sed -i '/^rsession-which-r=/d' /etc/rstudio/rserver.conf 2>/dev/null || true
CONF=/opt/python4Jup/etc/jupyter/jupyter_server_config.py
sed -i '/# >>> JupyDo RStudio/,/# <<< JupyDo RStudio/d' "$CONF" 2>/dev/null || true
if [ "${#ALL_R[@]}" -eq 0 ]; then
  echo "[install-rstudio] no R in this image: RStudio will use the R found on the PATH (install one later)"
else
  echo "rsession-which-r=${ALL_R[0]}" >> /etc/rstudio/rserver.conf
  echo "[install-rstudio] RStudio: ${ALL_R[0]}"
  if [ "${#ALL_R[@]}" -gt 1 ]; then
    mkdir -p "$(dirname "$CONF")"
    {
      echo "# >>> JupyDo RStudio: one more RStudio for every other R of the image"
      echo "import os"
      echo "from jupyter_rsession_proxy import setup_rserver"
      echo "def _jupydo_rstudio(r, prefix, title):"
      echo "    proc = setup_rserver(r, prefix, title)"
      echo "    env = proc['environment']"
      echo "    # its own settings and sessions, apart from the other RStudio"
      echo "    proc['environment'] = lambda port, unix_socket: dict(env(port, unix_socket),"
      echo "        RSTUDIO_DATA_HOME=os.path.expanduser('~/.local/share/' + prefix),"
      echo "        RSTUDIO_CONFIG_HOME=os.path.expanduser('~/.config/' + prefix))"
      echo "    return proc"
      n=1
      for r in "${ALL_R[@]:1}"; do
        n=$((n + 1))
        v="$("$r" --slave -e 'cat(as.character(getRversion()))' 2>/dev/null || echo "?")"
        where="$(dirname "$(dirname "$r")")"
        echo "c.ServerProxy.servers.update({'rstudio-${n}': _jupydo_rstudio('${r}', 'rstudio-${n}', 'RStudio (R ${v}, ${where})')})"
        echo "[install-rstudio] RStudio (R ${v}, ${where}): ${r}" >&2
      done
      echo "# <<< JupyDo RStudio"
    } >> "$CONF"
  fi
fi
# the program must be there (its --version may exit non-zero during a build)
[ -x "$RSERVER" ] || RSERVER="$(command -v rserver || true)"
[ -n "$RSERVER" ] || { echo "ERROR: rserver not found after the installation" >&2; exit 1; }
echo "[install-rstudio] $("$RSERVER" --version 2>&1 | head -1 || true)"
