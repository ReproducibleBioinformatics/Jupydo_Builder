#!/usr/bin/env bash
# VS Code module, run by the Dockerfile as root when the image is built with it.
# Installs, offline, from the bundle in $1 (vendor/vscode/<key>):
#   - code-server (VS Code in the browser) in /opt/code-server, on the PATH;
#   - the extensions of the bundle (Python, R...), in the user's VS Code folder
#     (/home/jovyan: at start the entrypoint gives it to the user, who can add more);
#   - the JupyterLab extension that adds "VS Code" to the launcher and starts
#     code-server as the user, behind the JupyterLab login, in /sharedFolder.
set -euo pipefail
BUNDLE="${1:?usage: install-vscode.sh <bundle folder>}"

# Extracted with JupyDo's own Python, not the image's tar: the same on every
# distribution, and the tar of Ubuntu 26.04 uses a system call that older QEMU
# emulation (arm64 images built on amd64) does not know ("Function not implemented")
mkdir -p /opt/code-server
/opt/python4Jup/bin/python3 - "${BUNDLE}/files/code-server.tar.gz" /opt/code-server <<'PYEOF'
import sys
import tarfile

src, dest = sys.argv[1:3]
strip = lambda name: name.split("/", 1)[1] if "/" in name else ""   # like --strip-components=1
with tarfile.open(src) as tf:
    members = []
    for m in tf.getmembers():
        m.name = strip(m.name)
        if not m.name:
            continue
        if m.islnk():  # hard links name their target with the top folder too
            m.linkname = strip(m.linkname)
        members.append(m)
    tf.extractall(dest, members=members, filter="fully_trusted")   # checksummed bundle
PYEOF
ln -sf /opt/code-server/bin/code-server /usr/local/bin/code-server

DATA=/home/jovyan/.local/share/code-server
mkdir -p "${DATA}/extensions" "${DATA}/User"
args=()
while read -r vsix; do
  [ -n "$vsix" ] && args+=(--install-extension "${BUNDLE}/files/extensions/${vsix}")
done < "${BUNDLE}/files/extensions/order.txt"
if [ "${#args[@]}" -gt 0 ]; then
  # Only the bundle's files: with a registry, code-server would also download the
  # members of extension packs by itself (already in the bundle, or not wanted), so
  # during this command its registry points nowhere. Users keep the normal one.
  HOME=/home/jovyan EXTENSIONS_GALLERY='{"serviceUrl": "http://127.0.0.1:9/vscode/gallery", "itemUrl": "http://127.0.0.1:9/vscode/item"}' \
    /opt/code-server/bin/code-server --user-data-dir "$DATA" \
    --extensions-dir "${DATA}/extensions" --force "${args[@]}"
fi
# no telemetry, no update checks (offline environments)
[ -f "${DATA}/User/settings.json" ] || printf '{\n  "telemetry.telemetryLevel": "off",\n  "update.mode": "none",\n  "extensions.autoCheckUpdates": false\n}\n' > "${DATA}/User/settings.json"

# the launcher icon and the proxy, into JupyDo's Python (never the image's)
/opt/python4Jup/bin/python3 -m pip install --quiet --disable-pip-version-check --no-index \
  --no-cache-dir --root-user-action=ignore --find-links "${BUNDLE}/wheels" jupyter-vscode-proxy jupyter-server-proxy
# VS Code opens in the same place as JupyterLab
CONF=/opt/python4Jup/etc/jupyter/jupyter_server_config.py
mkdir -p "$(dirname "$CONF")"
sed -i '/# >>> JupyDo VS Code/,/# <<< JupyDo VS Code/d' "$CONF" 2>/dev/null || true
printf '%s\n' "# >>> JupyDo VS Code" "import os" \
  "os.environ.setdefault('CODE_WORKINGDIR', '/sharedFolder')" "# <<< JupyDo VS Code" >> "$CONF"
echo "[install-vscode] code-server $(/opt/code-server/bin/code-server --version 2>/dev/null | head -1)," \
     "extensions: $(ls "${DATA}/extensions" | grep -v '\.json$' | tr '\n' ' ')"
