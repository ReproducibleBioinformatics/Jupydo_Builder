#!/usr/bin/env python3
"""For every image of a large-scale test list (scripts/bigtest/make-lists.py), the
architectures it is published for (amd64, arm64, ...), read from the registries'
metadata: nothing is downloaded and Docker's pull limits are not touched.
  quay.io     registry API (manifest of the pinned digest; for a single-architecture
              image, its configuration says which one)
  Docker Hub  Hub API of the tag (the architectures of its images), through curl
              (Docker Hub refuses Python's own HTTPS client), with the `docker login`
              account like make-lists.py
Writes <list>-arch.tsv (set, image, architectures) and prints a summary per set.
Usage: scripts/bigtest/arch-survey.py lists/bigtest/bigtest-<date>.tsv
"""
import collections
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import importlib.util  # noqa: E402

_spec = importlib.util.spec_from_file_location("make_lists", os.path.join(os.path.dirname(__file__), "make-lists.py"))
ml = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ml)

LISTS = ("application/vnd.oci.image.index.v1+json", "application/vnd.docker.distribution.manifest.list.v2+json")
ACCEPT = ", ".join(LISTS + ("application/vnd.oci.image.manifest.v1+json",
                            "application/vnd.docker.distribution.manifest.v2+json"))


def quay_get(path, token, accept=None):
    req = urllib.request.Request("https://quay.io/v2/" + path,
                                 headers={"Authorization": "Bearer " + token, "Accept": accept or ACCEPT})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def quay_arch(repo, digest):
    """repo: biocontainers/<name>"""
    tok = ml.get(f"https://quay.io/v2/auth?service=quay.io&scope=repository:{repo}:pull")["token"]
    m = quay_get(f"{repo}/manifests/{digest}", tok)
    if m.get("mediaType") in LISTS or "manifests" in m:
        return sorted({p["platform"]["architecture"] + ("/" + p["platform"]["variant"] if p["platform"].get("variant") else "")
                       for p in m["manifests"] if p.get("platform", {}).get("os") == "linux"})
    cfg = quay_get(f"{repo}/blobs/{m['config']['digest']}", tok, accept="*/*")
    return [cfg.get("architecture", "?")]


def hub_arch(repo, tag):
    repo = repo if "/" in repo else "library/" + repo
    t = ml.get(f"https://hub.docker.com/v2/repositories/{repo}/tags/{tag}")
    return sorted({i["architecture"] + ("/" + i["variant"] if i.get("variant") else "")
                   for i in t.get("images") or [] if i.get("os") == "linux"})


def main():
    src = sys.argv[1]
    out = src.replace(".tsv", "") + "-arch.tsv"
    done = {}
    if os.path.exists(out):  # restartable: images already looked up are kept
        for line in open(out):
            p = line.rstrip("\n").split("\t")
            if len(p) == 3 and p[0] != "set":
                done[p[1]] = p
    ml.hub_login()
    rows = [l.rstrip("\n").split("\t") for l in open(src) if l.strip() and not l.startswith("#")]
    with open(out, "a") as f:
        if not done:
            f.write("set\timage\tarchitectures\n")
        for n, r in enumerate(rows, 1):
            s, image, repo, tag = r[0], r[1], r[2], r[3]
            if image in done:
                continue
            digest = image.rsplit("@", 1)[1]
            try:
                if repo.startswith("quay.io/"):
                    arch = quay_arch(repo[len("quay.io/"):], digest)
                else:
                    arch = hub_arch(repo, tag)
            except Exception as e:  # noqa: BLE001 - recorded, the survey goes on
                arch = ["error:" + type(e).__name__]
            done[image] = [s, image, ",".join(arch) or "?"]
            f.write("\t".join(done[image]) + "\n")
            f.flush()
            print(f"\r  {n}/{len(rows)}", end="", file=sys.stderr)
    print(file=sys.stderr)
    by = collections.defaultdict(collections.Counter)
    for s, _, a in done.values():
        archs = set(a.split(","))
        kind = ("amd64 + arm64" if {"amd64", "arm64"} <= archs or {"amd64", "arm64/v8"} <= archs
                else "amd64 only" if archs & {"amd64"} else "arm64 only" if archs & {"arm64", "arm64/v8"}
                else a)
        by[s][kind] += 1
    print(out)
    for s in ("biocontainers", "staphb", "dockerhub"):
        total = sum(by[s].values())
        print(f"  {s} ({total}): " + ", ".join(f"{k} {v} ({100 * v / max(total, 1):.0f}%)"
                                                 for k, v in by[s].most_common()))


if __name__ == "__main__":
    main()
