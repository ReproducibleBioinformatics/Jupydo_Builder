#!/usr/bin/env python3
"""
Builds the offline R repositories for the Jupyter R kernel, one per CRAN snapshot
of lists/r-snapshots.txt, in vendor/r/<name>/src/contrib/ (the layout R expects
for repos = "file:///...").

For each snapshot: reads the CRAN index frozen at that date (Posit Package
Manager), resolves the recursive dependencies of lists/r-packages.txt (Depends,
Imports, LinkingTo), downloads the source packages, checks them against the MD5
published in the index, and writes the repository index (PACKAGES) + SHA256SUMS.
Sources only: the R of the image compiles them at build time, whatever version.

Usage (from the builder folder):  scripts/make-vendor-r.py
Only the Python standard library is needed (no R, no Docker).
"""
import gzip
import hashlib
import os
import re
import sys
import time
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE_URL = os.environ.get("CRAN_SNAPSHOT_URL", "https://packagemanager.posit.co/cran")
# Shipped with every R installation: never downloaded
R_BASE = {"R", "base", "compiler", "datasets", "graphics", "grDevices", "grid", "methods",
          "parallel", "splines", "stats", "stats4", "tcltk", "tools", "utils"}


def read_list(path):
    rows = []
    with open(path) as f:
        for line in f:
            line = line.split("#", 1)[0].strip()
            if line:
                rows.append(line.split())
    return rows


def fetch(url, tries=3):
    for attempt in range(1, tries + 1):
        try:
            with urllib.request.urlopen(url, timeout=120) as response:
                return response.read()
        except OSError as e:
            if attempt == tries:
                raise RuntimeError("cannot download {}: {}".format(url, e))
            time.sleep(2 * attempt)


def parse_dcf(text):
    """CRAN PACKAGES file -> {package: (fields dict, raw entry text)}."""
    index = {}
    for entry in re.split(r"\n\s*\n", text.strip()):
        fields, key = {}, None
        for line in entry.splitlines():
            if line[:1].isspace() and key:
                fields[key] += " " + line.strip()
            elif ":" in line:
                key, value = line.split(":", 1)
                fields[key] = value.strip()
        if "Package" in fields:
            index[fields["Package"]] = (fields, entry.strip())
    return index


def dependencies(fields):
    deps = set()
    for key in ("Depends", "Imports", "LinkingTo"):
        for item in fields.get(key, "").split(","):
            name = re.sub(r"\(.*\)", "", item).strip()
            if name and name not in R_BASE:
                deps.add(name)
    return deps


def resolve(index, top_level):
    needed, todo = set(), list(top_level)
    while todo:
        name = todo.pop()
        if name in needed:
            continue
        if name not in index:
            raise RuntimeError("package not in the snapshot: " + name)
        needed.add(name)
        todo.extend(dependencies(index[name][0]) - needed)
    return sorted(needed)


def build_snapshot(name, date, r_versions, top_level):
    out = os.path.join(ROOT, "vendor", "r", name)
    contrib = os.path.join(out, "src", "contrib")
    os.makedirs(contrib, exist_ok=True)
    url = "{}/{}/src/contrib".format(BASE_URL, date)
    print("=== R snapshot {} ({}, for R {}) ===".format(name, date, r_versions))
    index = parse_dcf(fetch(url + "/PACKAGES").decode("utf-8"))
    packages = resolve(index, top_level)
    print("{} packages: {}".format(len(packages), ", ".join(packages)))

    entries, sums = [], []
    for pkg in packages:
        fields, raw = index[pkg]
        filename = "{}_{}.tar.gz".format(pkg, fields["Version"])
        path = os.path.join(contrib, filename)
        expected_md5 = fields.get("MD5sum")
        if not (os.path.exists(path) and expected_md5 and
                hashlib.md5(open(path, "rb").read()).hexdigest() == expected_md5):
            data = fetch(url + "/" + filename)
            if expected_md5 and hashlib.md5(data).hexdigest() != expected_md5:
                raise RuntimeError("checksum mismatch for " + filename)
            with open(path, "wb") as f:
                f.write(data)
        sums.append("{}  {}".format(hashlib.sha256(open(path, "rb").read()).hexdigest(), filename))
        entries.append(raw)

    # remove sources of an older resolution of this snapshot
    keep = {"{}_{}.tar.gz".format(p, index[p][0]["Version"]) for p in packages}
    for old in os.listdir(contrib):
        if old.endswith(".tar.gz") and old not in keep:
            os.remove(os.path.join(contrib, old))

    text = "\n\n".join(entries) + "\n"
    with open(os.path.join(contrib, "PACKAGES"), "w") as f:
        f.write(text)
    with gzip.GzipFile(os.path.join(contrib, "PACKAGES.gz"), "wb", mtime=0) as f:
        f.write(text.encode("utf-8"))
    with open(os.path.join(out, "SHA256SUMS"), "w") as f:
        f.write("\n".join(sums) + "\n")
    with open(os.path.join(out, "manifest.txt"), "w") as f:
        f.write("snapshot={}\ndate={}\nr_versions={}\nsource={}\ntop_level={}\npackages={}\n".format(
            name, date, r_versions, url, ",".join(top_level), len(packages)))
        f.write("".join("{}\t{}\n".format(p, index[p][0]["Version"]) for p in packages))
    open(os.path.join(out, ".complete"), "w").close()
    print("OK {}: {} sources".format(name, len(packages)))


def main():
    top_level = [row[0] for row in read_list(os.path.join(ROOT, "lists", "r-packages.txt"))]
    snapshots = read_list(os.path.join(ROOT, "lists", "r-snapshots.txt"))
    for name, date, r_versions in snapshots:
        build_snapshot(name, date, r_versions, top_level)
    # for the image build: which snapshot serves which R versions
    with open(os.path.join(ROOT, "vendor", "r", "snapshots.txt"), "w") as f:
        f.write("".join("{} {} {}\n".format(*row) for row in snapshots))


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        sys.exit("ERROR: {}".format(e))
