#!/usr/bin/env python3
"""Starts the IGV server exactly as JupyterLab does (the command of the 'igv' entry of
jupyter-server-proxy, from JupyDo's JupyterLab configuration) and checks that the
IGV-Web app answers with the script that sends real paths (/sharedFolder/...) to the
server, and that a file given by its real path can be read with a range request, as
IGV reads BAM files. Run by scripts/test-all.sh inside the image, as a
normal user, with JupyDo's Python. Exit 0 = IGV works."""
import http.client
import os
import subprocess
import sys
import tempfile
import time

from jupyter_server.serverapp import ServerApp
from jupyter_server_proxy.config import ServerProxy

os.environ["JUPYTER_RUNTIME_DIR"] = tempfile.mkdtemp()
app = ServerApp()
app.initialize(argv=["--port=0"], find_extensions=False, new_httpserver=False)
proc = ServerProxy(config=app.config).servers["igv"]
PORT = 8790
data = tempfile.mkdtemp()  # any folder of the environment, given by its real path
with open(os.path.join(data, "sample.bam"), "wb") as f:
    f.write(bytes(range(256)) * 400)
cmd = [c.format(port=PORT) for c in proc.command]
print("command:", " ".join(cmd), flush=True)
server = subprocess.Popen(cmd)


def get(path, headers=None):
    c = http.client.HTTPConnection("127.0.0.1", PORT, timeout=5)
    c.request("GET", path, headers=headers or {})
    r = c.getresponse()
    return r.status, r.read()


ok = False
for _ in range(30):
    time.sleep(1)
    try:
        app_status, page = get("/")
        rng_status, part = get("/__fs__" + os.path.join(data, "sample.bam"), {"Range": "bytes=256-511"})
        ok = (app_status == 200 and b"igv" in page.lower() and b"__fs__" in page
              and rng_status == 206 and part == bytes(range(256)))
        break
    except OSError:
        continue
print("IGV works (app page, a file read by its real path with a range request)" if ok
      else "IGV does not work (app: %s, range: %s)" % (locals().get("app_status"), locals().get("rng_status")))
server.terminate()
sys.exit(0 if ok else 1)
