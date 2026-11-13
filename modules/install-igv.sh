#!/usr/bin/env bash
# IGV module, run by the Dockerfile as root when the image is built with it.
# Installs, offline, from the bundle in $1 (vendor/igv/<key>):
#   - the IGV-Web app (static files) in /opt/igv-webapp;
#   - the small server that serves it with the user's shared folder (igv-serve.py);
#   - the launcher icon "IGV" (jupyter-server-proxy), in JupyDo's own Python.
set -euo pipefail
BUNDLE="${1:?usage: install-igv.sh <bundle folder>}"
HERE="$(dirname "$(readlink -f "$0")")"

# unzipped with JupyDo's Python (no unzip needed in the image); a single top folder
# in the zip is stripped
/opt/python4Jup/bin/python3 - "${BUNDLE}/files/igv-webapp.zip" /opt/igv-webapp <<'PYEOF'
import os, shutil, sys, tempfile, zipfile
src, dest = sys.argv[1:3]
tmp = tempfile.mkdtemp()
zipfile.ZipFile(src).extractall(tmp)
entries = os.listdir(tmp)
top = os.path.join(tmp, entries[0]) if len(entries) == 1 and os.path.isdir(os.path.join(tmp, entries[0])) else tmp
shutil.rmtree(dest, ignore_errors=True)
shutil.copytree(top, dest)
shutil.rmtree(tmp)
PYEOF
[ -f /opt/igv-webapp/index.html ] || { echo "ERROR: the IGV-Web app has no index.html" >&2; exit 1; }
chmod -R a+rX /opt/igv-webapp
install -d /opt/jupydo
install -m 755 "${HERE}/igv-serve.py" /opt/jupydo/igv-serve.py
install -m 644 "${HERE}/igv-icon.svg" /opt/jupydo/igv-icon.svg

/opt/python4Jup/bin/python3 -m pip install --quiet --disable-pip-version-check --no-index \
  --no-cache-dir --root-user-action=ignore --find-links "${BUNDLE}/wheels" jupyter-server-proxy

# the launcher icon: JupyterLab starts the server on a free port, as the user
CONF=/opt/python4Jup/etc/jupyter/jupyter_server_config.py
mkdir -p "$(dirname "$CONF")"
sed -i '/# >>> JupyDo IGV/,/# <<< JupyDo IGV/d' "$CONF" 2>/dev/null || true
cat >> "$CONF" <<'PYEOF'
# >>> JupyDo IGV
c.ServerProxy.servers.update({'igv': {
    'command': ['/opt/python4Jup/bin/python3', '/opt/jupydo/igv-serve.py', '{port}'],
    'timeout': 30,
    'new_browser_tab': False,
    'launcher_entry': {'title': 'IGV', 'icon_path': '/opt/jupydo/igv-icon.svg'},
}})
# <<< JupyDo IGV
PYEOF
echo "[install-igv] IGV-Web installed in /opt/igv-webapp"
