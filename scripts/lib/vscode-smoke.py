#!/usr/bin/env python3
"""Starts code-server exactly as JupyterLab does (command from jupyter-vscode-proxy
itself) and waits until it answers. Run by scripts/test-all.sh inside the image, as
a normal user, with JupyDo's Python. Exit 0 = VS Code answered."""
import http.client
import os
import subprocess
import sys
import tempfile
import time

from jupyter_vscode_proxy import setup_vscode

PORT = 8788
os.environ.setdefault("CODE_WORKINGDIR", "/sharedFolder")
cmd = [c.format(port=PORT, unix_socket="") for c in setup_vscode()["command"](PORT, "")]
print("command:", " ".join(cmd), flush=True)
log = tempfile.TemporaryFile(mode="w+")
server = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
status = None
for _ in range(90):
    time.sleep(2)
    if server.poll() is not None:
        break
    try:
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
        c.request("GET", "/")
        status = c.getresponse().status
        if status in (200, 302):
            break
    except OSError:
        pass
ok = status in (200, 302)
ext = os.path.expanduser("~/.local/share/code-server/extensions")
print(f"VS Code answered (HTTP {status}); extensions: "
      + " ".join(sorted(d for d in os.listdir(ext) if not d.endswith(".json"))) if ok and os.path.isdir(ext)
      else f"VS Code answered (HTTP {status})" if ok else f"VS Code did not answer (last HTTP status: {status})")
if not ok:
    log.seek(0)
    print("--- code-server output ---\n" + log.read()[-3000:])
server.terminate()
sys.exit(0 if ok else 1)
