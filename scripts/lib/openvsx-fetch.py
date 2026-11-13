#!/usr/bin/env python3
"""Downloads VS Code extensions from Open VSX with all their dependencies and the
members of their extension packs (otherwise code-server downloads those itself while
the image is built: the result would depend on the network and on the day).
Usage: openvsx-fetch.py <extensions list> <target: linux-x64|linux-arm64> <out folder>
Writes <out>/<publisher.name>-<version>.vsix and <out>/order.txt (dependencies first,
the order to install them) and prints what it took."""
import json
import os
import sys
import urllib.error
import urllib.request

API = "https://open-vsx.org/api"
listfile, target, out = sys.argv[1:4]
os.makedirs(out, exist_ok=True)


def get(url):
    with urllib.request.urlopen(url, timeout=60) as r:
        return json.load(r)


def meta(ext_id):
    ns, name = ext_id.split(".", 1)
    try:  # a build for this platform, if the extension has one
        return get(f"{API}/{ns}/{name}/{target}/latest")
    except urllib.error.HTTPError as e:
        if e.code != 404:
            raise
    return get(f"{API}/{ns}/{name}/latest")


order, seen = [], set()


def take(ext_id, optional=False):
    key = ext_id.lower()
    if key in seen:
        return
    seen.add(key)
    try:
        m = meta(ext_id)
    except urllib.error.HTTPError as e:
        # an extension pack member that is not on Open VSX (e.g. Microsoft's
        # proprietary Pylance) is left out; a missing dependency is an error
        if optional and e.code == 404:
            print(f"  {ext_id}: not on Open VSX, left out (member of an extension pack, optional)")
            return
        raise
    for dep in m.get("dependencies") or []:  # extensionDependencies: required, installed first
        take(f"{dep['namespace']}.{dep['extension']}")
    for dep in m.get("bundledExtensions") or []:  # extensionPack members: optional
        take(f"{dep['namespace']}.{dep['extension']}", optional=True)
    fname = f"{m['namespace']}.{m['name']}-{m['version']}.vsix"
    urllib.request.urlretrieve(m["files"]["download"], os.path.join(out, fname))
    order.append(fname)
    print(f"  {m['namespace']}.{m['name']} {m['version']} ({m.get('targetPlatform', 'universal')})")


for line in open(listfile):
    line = line.split("#")[0].strip()
    if line:
        take(line)
with open(os.path.join(out, "order.txt"), "w") as f:
    f.write("\n".join(order) + "\n")
