#!/usr/bin/env python3
"""Publishes on Zenodo everything JupyDo needs to build environments offline, as a new
version of the same Zenodo record (same concept DOI, a DOI per version):

  vendor-<bundle>.tar           each folder of vendor/ (made here with make-vendor-*.sh),
                                as it is (the bundles inside are already compressed)
  jupydo-builder-src.tar.gz     the builder itself (Dockerfiles, modules, scripts...)
  jupydo-hub-<arch>.tar.gz      the JupyDo hub image (docker save), amd64 and arm64,
                                taken from ghcr.io where GitHub builds it (--hub-image)
  SHA256SUMS                    the checksum of every file above

JupyDo's first_start.sh downloads these files from the record named in it, checks them
against SHA256SUMS and puts them in place: no copy by hand.

Steps (each can be run alone):
  1. pack:    scripts/publish-zenodo.py --out /big/disk/zenodo-files [--hub-image IMAGE]
  2. upload:  ZENODO_TOKEN=... scripts/publish-zenodo.py --out ... --upload [--sandbox]
              (a DRAFT on Zenodo: check it on the web page it prints)
  3. publish: add --publish to step 2, or press "Publish" on the Zenodo page. A published
              version cannot be changed or deleted any more.
--sandbox uses sandbox.zenodo.org (a test copy of Zenodo, with its own account and
token): try everything there first. The token is read from ZENODO_TOKEN (Zenodo ->
Applications -> Personal access tokens, scopes deposit:write and deposit:actions).
The record and its description are in zenodo.json: a draft not published yet is
filled, a published record gets a new version (the new id is written there).
"""
import argparse
import datetime
import hashlib
import http.client
import json
import os
import subprocess
import sys
import tarfile
import urllib.parse
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "zenodo.json")
SOURCE_PARTS = ["Dockerfile", "Dockerfile.convert", "vendor_list.txt", "modules", "scripts", "security",
                "lists", "docs", "zenodo.json", ".gitignore"]
ARCHS = ("amd64", "arm64")


def say(*a):
    print(*a, flush=True)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(8 << 20), b""):
            h.update(block)
    return h.hexdigest()


# ------------------------------------------------------------------ 1. pack
def pack(out, hub_image):
    os.makedirs(out, exist_ok=True)
    vendor = os.path.join(ROOT, "vendor")
    bundles = sorted(d for d in os.listdir(vendor) if os.path.isdir(os.path.join(vendor, d)))
    if not bundles:
        sys.exit(f"ERROR: {vendor} is empty: run the make-vendor-*.sh scripts first")
    for b in bundles:
        incomplete = [os.path.relpath(os.path.join(dp), vendor) for dp, dn, fn in os.walk(os.path.join(vendor, b))
                      if "manifest.txt" in fn and ".complete" not in fn]
        if incomplete:
            sys.exit(f"ERROR: unfinished bundle(s) in vendor/: {', '.join(incomplete)} (no .complete marker): "
                     "run its make-vendor script again")
    for b in bundles:
        target = os.path.join(out, f"vendor-{b}.tar")
        say(f"packing vendor/{b} -> {os.path.basename(target)}")
        with tarfile.open(target + ".part", "w") as t:
            t.add(os.path.join(vendor, b), arcname=b)
        os.replace(target + ".part", target)
    target = os.path.join(out, "jupydo-builder-src.tar.gz")
    say(f"packing the builder source -> {os.path.basename(target)}")
    with tarfile.open(target + ".part", "w:gz") as t:
        for part in SOURCE_PARTS:
            if os.path.exists(os.path.join(ROOT, part)):
                t.add(os.path.join(ROOT, part), arcname=f"jupydo-builder/{part}",
                      filter=lambda i: None if "__pycache__" in i.name else i)
    os.replace(target + ".part", target)
    if hub_image:
        for arch in ARCHS:
            target = os.path.join(out, f"jupydo-hub-{arch}.tar.gz")
            say(f"saving {hub_image} ({arch}) -> {os.path.basename(target)}")
            subprocess.run(["docker", "pull", "-q", "--platform", f"linux/{arch}", hub_image], check=True)
            with open(target + ".part", "wb") as f:
                save = subprocess.Popen(["docker", "save", hub_image], stdout=subprocess.PIPE)
                subprocess.run(["gzip", "-1"], stdin=save.stdout, stdout=f, check=True)
                if save.wait() != 0:
                    sys.exit("ERROR: docker save failed")
            os.replace(target + ".part", target)
    else:
        say("no --hub-image: the hub image is not included")
    files = sorted(f for f in os.listdir(out) if f != "SHA256SUMS" and not f.endswith(".part"))
    with open(os.path.join(out, "SHA256SUMS"), "w") as s:
        for f in files:
            say(f"  sha256 {f}")
            s.write(f"{sha256(os.path.join(out, f))}  {f}\n")
    total = sum(os.path.getsize(os.path.join(out, f)) for f in files)
    say(f"Ready in {out}: {len(files)} files, {total / 1e9:.1f} GB (Zenodo allows 50 GB per record)")


# ------------------------------------------------------------------ 2. upload
class Zenodo:
    def __init__(self, sandbox):
        self.api = "https://sandbox.zenodo.org/api" if sandbox else "https://zenodo.org/api"
        self.token = os.environ.get("ZENODO_TOKEN") or sys.exit("ERROR: set ZENODO_TOKEN (see --help)")

    def call(self, method, url, body=None):
        url = url if url.startswith("http") else self.api + url
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": "Bearer " + self.token, "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                text = r.read()
                return json.loads(text) if text else {}
        except urllib.error.HTTPError as e:
            sys.exit(f"ERROR: Zenodo {method} {url}: HTTP {e.code} {e.read().decode(errors='replace')[:500]}")

    def put_file(self, bucket, path):
        """Streams a (big) file into the record's bucket."""
        u = urllib.parse.urlparse(f"{bucket}/{urllib.parse.quote(os.path.basename(path))}")
        conn = http.client.HTTPSConnection(u.netloc, timeout=600)
        size = os.path.getsize(path)
        with open(path, "rb") as f:
            conn.request("PUT", u.path, body=f, headers={"Authorization": "Bearer " + self.token,
                                                         "Content-Type": "application/octet-stream",
                                                         "Content-Length": str(size)})
            r = conn.getresponse()
            text = r.read().decode(errors="replace")
        if r.status not in (200, 201):
            sys.exit(f"ERROR: upload of {os.path.basename(path)}: HTTP {r.status} {text[:500]}")


def upload(out, sandbox, publish):
    cfg = json.load(open(CONFIG))
    key = "sandbox_record" if sandbox else "record"
    z = Zenodo(sandbox)
    files = sorted(f for f in os.listdir(out) if not f.endswith(".part"))
    if "SHA256SUMS" not in files:
        sys.exit(f"ERROR: no SHA256SUMS in {out}: run the pack step first")
    current = z.call("GET", f"/deposit/depositions/{cfg[key]}") if cfg.get(key) else None
    if current and not current.get("submitted"):   # a draft not published yet: fill it
        say(f"filling the unpublished draft {cfg[key]}")
        draft = current
    elif current:   # a new version of the same record
        say(f"new version of record {cfg[key]}")
        r = z.call("POST", f"/deposit/depositions/{cfg[key]}/actions/newversion")
        draft = z.call("GET", r["links"]["latest_draft"])
    if current:
        for f in draft.get("files", []):   # start from no files (the old version's, or a past try)
            z.call("DELETE", f"/deposit/depositions/{draft['id']}/files/{f['id']}")
    else:
        say("first upload: a new record")
        draft = z.call("POST", "/deposit/depositions", {})
    # metadata already written on the Zenodo page (title, authors...) are kept; zenodo.json
    # only fills a record that has none yet
    meta = dict(draft.get("metadata") or {}) if (draft.get("metadata") or {}).get("title") else dict(cfg["metadata"])
    meta["version"] = datetime.date.today().isoformat()
    meta["publication_date"] = meta["version"]
    z.call("PUT", f"/deposit/depositions/{draft['id']}", {"metadata": meta})
    for f in files:
        size = os.path.getsize(os.path.join(out, f)) / 1e9
        say(f"uploading {f} ({size:.2f} GB)")
        z.put_file(draft["links"]["bucket"], os.path.join(out, f))
    cfg[key] = draft["id"]
    with open(CONFIG, "w") as fh:
        json.dump(cfg, fh, indent=2)
        fh.write("\n")
    page = draft["links"]["html"]
    if publish:
        done = z.call("POST", f"/deposit/depositions/{draft['id']}/actions/publish")
        say(f"PUBLISHED: record {done['id']}, DOI {done.get('doi')} ({page})")
        say(f"Put this record id in JupyDo's first_start.sh: JUPYDO_VENDOR_RECORD={done['id']}")
    else:
        say(f"DRAFT ready: check it at {page}, then publish it there (or run again with --publish).")
        say(f"After publishing, put its record id in JupyDo's first_start.sh: JUPYDO_VENDOR_RECORD={draft['id']}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", required=True, help="folder for the files to publish (about 15 GB)")
    ap.add_argument("--hub-image", help="the hub image to include, e.g. ghcr.io/reproduciblebioinformatics/jupydo-hub:<tag>")
    ap.add_argument("--upload", action="store_true", help="upload the files already packed in --out")
    ap.add_argument("--publish", action="store_true", help="publish the new version (cannot be undone)")
    ap.add_argument("--sandbox", action="store_true", help="use sandbox.zenodo.org (a test copy of Zenodo)")
    a = ap.parse_args()
    if a.upload:
        upload(a.out, a.sandbox, a.publish)
    else:
        pack(a.out, a.hub_image)


if __name__ == "__main__":
    main()
