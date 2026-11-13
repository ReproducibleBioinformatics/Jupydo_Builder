#!/usr/bin/env python3
"""Starts RStudio Server exactly as JupyterLab does (the command and environment come
from jupyter-rsession-proxy itself, the extension behind the launcher icon) and waits
until it answers. Run by scripts/test-all.sh rstudio inside the image, as a normal
user, with JupyDo's Python. Exit 0 = RStudio answered."""
import http.client
import os
import subprocess
import sys
import tempfile
import time

from jupyter_rsession_proxy import setup_rserver

PORT = 8787
proc_def = setup_rserver()
cmd = [c.format(port=PORT, unix_socket="", base_url="/") for c in proc_def["command"](PORT, None)]
env = dict(os.environ, **proc_def["environment"](PORT, None))
print("command:", " ".join(cmd), flush=True)
log = tempfile.TemporaryFile(mode="w+")
server = subprocess.Popen(cmd, env=env, stdout=log, stderr=subprocess.STDOUT)
status = None
for _ in range(60):
    time.sleep(2)
    if server.poll() is not None:
        break
    try:
        c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
        c.request("GET", "/", headers={"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) Firefox/140.0"})
        status = c.getresponse().status
        if status in (200, 302):
            break
    except OSError:
        pass
ok = status in (200, 302)
print(f"RStudio Server answered (HTTP {status})" if ok else f"RStudio Server did not answer (last HTTP status: {status})")
if not ok:
    log.seek(0)
    print("--- rserver output ---\n" + log.read()[-3000:])
    for f in ("/var/log/rstudio/rstudio-server/rserver.log",
              os.path.expanduser("~/.local/share/rstudio/log/rserver.log")):
        try:
            print(f"--- {f} ---\n" + open(f, errors="replace").read()[-3000:])
        except OSError:
            pass
server.terminate()
sys.exit(0 if ok else 1)
