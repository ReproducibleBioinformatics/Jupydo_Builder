#!/bin/bash
# Verifies that the JupyDo stack is installed and working.
# Exit code 0 = ready. Run at the end of every build, and by JupyDo on an
# image before starting it.
PY=/opt/python4Jup/bin
FAIL=0
ok() { echo "OK   $1"; }
ko() { echo "FAIL $1"; FAIL=1; }

if [ -x "$PY/python3" ]; then ok "python4Jup ($("$PY/python3" --version 2>&1))"; else ko "python4Jup missing ($PY/python3)"; fi

if V="$("$PY/jupyterhub-singleuser" --version 2>/dev/null)"; then ok "jupyterhub-singleuser $V"
else ko "jupyterhub-singleuser not working"; fi

if V="$("$PY/jupyter" lab --version 2>/dev/null)"; then ok "jupyterlab $V"
else ko "jupyterlab not working"; fi

# Kernels: the Pythons and Rs of the image (registered and test-started during the
# build, /opt/jupydo/kernels.json); JupyDo's own Python must NOT be a kernel.
if [ -f /opt/jupydo/kernels.json ]; then
  "$PY/python3" - <<'EOF_KERNELS'
import json
for k in json.load(open("/opt/jupydo/kernels.json")):
    if k["ok"]:
        print("OK   kernel " + k["display_name"])
    else:
        print("WARN {} is not a kernel: {}".format(k["display_name"], (k["error"] or "")[:200]))
EOF_KERNELS
  N="$("$PY/python3" -c 'import json; print(sum(k["ok"] for k in json.load(open("/opt/jupydo/kernels.json"))))')"
  [ "$N" -gt 0 ] || echo "INFO no kernels: the image has no Python or R usable as a kernel (the terminal works)"
else
  ko "kernel registration report missing (/opt/jupydo/kernels.json)"
fi
if [ -e "$PY/share/jupyter/kernels/python3" ]; then ko "JupyDo's own Python is registered as a kernel"; fi

# packages of the image stepped back to the bundle's version during the build
# (the image was newer than the apt bundle): the build works, but say it
if [ -s /opt/jupydo/apt-downgrades.txt ]; then
  while read -r line; do echo "WARN stepped back to the bundle's version: $line"; done < /opt/jupydo/apt-downgrades.txt
fi
[ -s /opt/jupydo/ld-paths.txt ] && echo "INFO $(cat /opt/jupydo/ld-paths.txt)"
if [ -s /opt/jupydo/apt-upgrades.txt ]; then
  while read -r line; do echo "WARN brought forward to the bundle's version (image older than the bundle): $line"; done < /opt/jupydo/apt-upgrades.txt
fi

# JupyDo's own Python must never be a kernel: ask the kernel list the way the
# JupyterLab server builds it (same configuration files)
if hidden="$(JUPYTER_RUNTIME_DIR="$(mktemp -d)" "$PY/python3" - 2>/dev/null <<'PYEOF'
from jupyter_server.serverapp import ServerApp
app = ServerApp()
app.initialize(argv=["--port=0"], find_extensions=False, new_httpserver=False)
ksm = app.kernel_spec_manager
bad = []
for name, path in ksm.find_kernel_specs().items():
    argv = ksm.get_kernel_spec(name).argv
    # the native kernel (ipykernel's own resources) or any kernel run by our Python
    if "/site-packages/ipykernel/" in path or argv[0].startswith("/opt/python4Jup") \
       or argv[0] in ("python", "python3"):
        bad.append(name)
print(" ".join(bad))
PYEOF
)"; then
  if [ -z "$hidden" ]; then ok "JupyDo's Python is not a kernel"
  else ko "JupyDo's own Python is visible as a kernel: ${hidden}"; fi
else ko "cannot list the kernels as JupyterLab does"; fi

# JupyDo images promise that users can compile (install.packages / pip install)
MISSING_TOOLS=""
for tool in gcc g++ gfortran make pkg-config; do
  command -v "$tool" >/dev/null 2>&1 || MISSING_TOOLS="$MISSING_TOOLS $tool"
done
if [ -z "$MISSING_TOOLS" ]; then ok "build tools (gcc, g++, gfortran, make, pkg-config)"
else ko "build tools missing:$MISSING_TOOLS"; fi

# The system package tools must keep working: users install software with sudo apt.
# (They break if libraries of the image shadow the system ones, e.g. a conda
# /usr/local/lib on a converted BioContainer.)
if PKG_ERR="$(dpkg-deb --version 2>&1 >/dev/null; apt-get --version 2>&1 >/dev/null; dpkg -s dpkg 2>&1 >/dev/null)" \
   && [ -z "$PKG_ERR" ]; then ok "package tools (dpkg, apt)"
else ko "package tools (dpkg, apt) do not work: $(echo "$PKG_ERR" | head -1)"; fi

if command -v setpriv >/dev/null 2>&1 || command -v gosu >/dev/null 2>&1; then ok "user switch (setpriv/gosu)"
else ko "no setpriv or gosu to switch to the user"; fi
if command -v sudo >/dev/null 2>&1; then ok "sudo"; else ko "sudo missing (add it to the apt bundle)"; fi
if [ -x /usr/local/bin/jupydo-entrypoint ]; then ok "entrypoint"; else ko "entrypoint missing"; fi

# optional modules the image was built with
case " ${JUPYDO_MODULES:-} " in
  *" apptainer "*)
    if apptainer --version >/dev/null 2>&1; then ok "module apptainer ($(apptainer --version))"
    else ko "module apptainer: apptainer missing or not working"; fi ;;
esac
case " ${JUPYDO_MODULES:-} " in
  *" igv "*)
    if [ -f /opt/igv-webapp/index.html ] && [ -x /opt/jupydo/igv-serve.py ] \
       && "$PY/python3" -c "import jupyter_server_proxy" 2>/dev/null \
       && grep -q "# >>> JupyDo IGV" /opt/python4Jup/etc/jupyter/jupyter_server_config.py 2>/dev/null; then
      ok "module igv (IGV-Web app; files opened by their real path, e.g. /sharedFolder/...)"
    else ko "module igv: the IGV-Web app, its server or the launcher entry missing"; fi ;;
esac
case " ${JUPYDO_MODULES:-} " in
  *" desktop "*)
    if command -v vncserver >/dev/null 2>&1 && command -v xfce4-session >/dev/null 2>&1 \
       && "$PY/python3" -c "import jupyter_remote_desktop_proxy, jupyter_server_proxy" 2>/dev/null; then
      ok "module desktop (XFCE, $(dpkg-query -W -f 'TigerVNC ${Version}' tigervnc-standalone-server 2>/dev/null || echo VNC))"
    else ko "module desktop: XFCE, the VNC server or its JupyterLab extension missing or not working"; fi ;;
esac
case " ${JUPYDO_MODULES:-} " in
  *" vscode "*)
    if CSV="$(code-server --version 2>/dev/null | head -1)" && [ -n "$CSV" ] \
       && "$PY/python3" -c "import jupyter_vscode_proxy, jupyter_server_proxy" 2>/dev/null; then
      NEXT="$(ls /home/jovyan/.local/share/code-server/extensions 2>/dev/null | grep -vc '\.json$' || true)"
      ok "module vscode (code-server ${CSV%% *}, ${NEXT:-0} extensions)"
    else ko "module vscode: code-server or its JupyterLab extension missing or not working"; fi ;;
esac
case " ${JUPYDO_MODULES:-} " in
  *" rstudio "*)
    RS=/usr/lib/rstudio-server/bin/rserver; [ -x "$RS" ] || RS="$(command -v rserver || true)"
    if [ -n "$RS" ] && RSV="$(dpkg-query -W -f '${Version}' rstudio-server 2>/dev/null || "$RS" --version 2>&1 | head -1)" \
       && "$PY/python3" -c "import jupyter_rsession_proxy, jupyter_server_proxy" 2>/dev/null; then
      RW="$(sed -n 's/^rsession-which-r=//p' /etc/rstudio/rserver.conf 2>/dev/null | tail -1)"
      MORE="$(grep -c "^c.ServerProxy.servers.update({'rstudio-" /opt/python4Jup/etc/jupyter/jupyter_server_config.py 2>/dev/null || true)"
      ok "module rstudio (RStudio Server ${RSV}, R: ${RW:-from the PATH when a session starts}${MORE:+; ${MORE} more for the other R})"
      [ -n "$RW" ] || command -v R >/dev/null 2>&1 \
        || echo "INFO RStudio is installed but the image has no R: install R (e.g. sudo apt install r-base) and RStudio will use it"
    else ko "module rstudio: RStudio Server or its JupyterLab extension missing or not working"; fi ;;
esac

exit $FAIL
