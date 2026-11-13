#!/usr/bin/env python3
"""Starts the desktop exactly as JupyterLab does (command from
jupyter-remote-desktop-proxy itself) and checks that the VNC server answers on its
socket and that the XFCE session is running. Run by scripts/test-all.sh inside the
image, as a normal user, with JupyDo's Python. Exit 0 = the desktop works."""
import os
import socket
import subprocess
import sys
import tempfile
import time

from jupyter_remote_desktop_proxy.setup_websockify import setup_websockify

# as JupyDo's JupyterLab sets them (modules/install-desktop.sh): the home is not writable
os.environ.setdefault("XAUTHORITY", os.path.join(os.path.expanduser("~"), ".cache", "Xauthority"))
os.environ.setdefault("ICEAUTHORITY", os.path.join(os.path.expanduser("~"), ".cache", "ICEauthority"))
sock = os.path.join(tempfile.mkdtemp(), "vnc.sock")
proc_def = setup_websockify()
cmd = [c.format(unix_socket=sock) for c in proc_def["command"]]
print("command:", " ".join(cmd), flush=True)
log = tempfile.TemporaryFile(mode="w+")
server = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)
banner = None
for _ in range(60):
    time.sleep(2)
    if server.poll() is not None:
        break
    if os.path.exists(sock):
        try:
            s = socket.socket(socket.AF_UNIX)
            s.settimeout(5)
            s.connect(sock)
            banner = s.recv(12).decode(errors="replace").strip()
            s.close()
            if banner.startswith("RFB"):
                break
        except OSError:
            pass
session = False
if banner and banner.startswith("RFB"):
    for _ in range(15):  # XFCE takes a few seconds to come up
        time.sleep(2)
        for pid in filter(str.isdigit, os.listdir("/proc")):  # no pgrep in every image
            try:
                with open(f"/proc/{pid}/cmdline", "rb") as f:
                    if b"xfce4-session" in f.read() and os.stat(f"/proc/{pid}").st_uid == os.getuid():
                        session = True
            except OSError:
                pass
        if session:
            break
ok = bool(banner and banner.startswith("RFB")) and session
print(f"Desktop works (VNC: {banner}, XFCE session running)" if ok
      else f"Desktop does not work (VNC banner: {banner}, XFCE session running: {session})")
if not ok:
    log.seek(0)
    print("--- vncserver output ---\n" + log.read()[-3000:])
    for f in sorted(os.listdir(os.path.expanduser("~/.vnc"))) if os.path.isdir(os.path.expanduser("~/.vnc")) else []:
        if f.endswith(".log"):
            print(f"--- ~/.vnc/{f} ---\n" + open(os.path.expanduser(f"~/.vnc/{f}"), errors="replace").read()[-3000:])
server.terminate()
sys.exit(0 if ok else 1)
