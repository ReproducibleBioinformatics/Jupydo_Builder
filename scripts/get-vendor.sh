#!/usr/bin/env bash
# Downloads the vendored bundles (vendor/) from Zenodo into this builder folder: every
# vendor-<bundle>.tar of the record, checked against the record's SHA256SUMS, then
# unpacked into vendor/. Resumable: run it again after an interruption. Nothing is
# downloaded again if vendor/ already holds that record.
#
# Usage (from the builder folder):  scripts/get-vendor.sh [RECORD]
#   RECORD  the Zenodo record id (default: "record" in zenodo.json)
# Needs about 16 GB for the download and as much again while unpacking (the download
# folder, vendor/.download-<record>, is deleted at the end).
set -euo pipefail
cd "$(dirname "$0")/.."

RECORD="${1:-$(python3 -c 'import json; print(json.load(open("zenodo.json"))["record"] or "")')}"
[ -n "$RECORD" ] || { echo "ERROR: no record: give it as argument or set \"record\" in zenodo.json" >&2; exit 1; }
BASE="${ZENODO_FILES_URL:-https://zenodo.org/records/$RECORD/files}"   # (the URL can be changed for tests)
DL="vendor/.download-$RECORD"
zget() { curl -fL --retry 5 --retry-delay 20 -A "JupyDo-builder/1.0 (+https://github.com/ReproducibleBioinformatics/Jupydo_Builder)" "$@"; }

if [ "$(cat vendor/.zenodo-record 2>/dev/null)" = "$RECORD" ]; then
    echo "vendor/ already holds Zenodo record $RECORD: nothing to do"; exit 0
fi
mkdir -p "$DL"
echo "Zenodo record $RECORD: reading SHA256SUMS"
zget -sS -o "$DL/SHA256SUMS" "$BASE/SHA256SUMS?download=1"
grep ' vendor-.*\.tar$' "$DL/SHA256SUMS" > "$DL/SHA256SUMS.vendor"
while read -r _ f; do
    echo "  $f"
    zget -C - --progress-bar -o "$DL/$f" "$BASE/$f?download=1"
done < "$DL/SHA256SUMS.vendor"
echo "checking the files..."
if ! (cd "$DL" && sha256sum --quiet -c SHA256SUMS.vendor); then
    (cd "$DL" && sha256sum -c SHA256SUMS.vendor 2>/dev/null | sed -n 's/: FAILED.*//p' | xargs -r rm -f)
    echo "ERROR: some files were damaged and have been deleted: run this again to download them" >&2
    exit 1
fi
echo "unpacking into vendor/ ..."
for t in "$DL"/vendor-*.tar; do
    b="$(basename "$t" .tar)"; b="${b#vendor-}"
    rm -rf "vendor/$b"
    tar -xf "$t" -C vendor
done
echo "$RECORD" > vendor/.zenodo-record
rm -rf "$DL"
echo "vendor/ ready (Zenodo record $RECORD, doi:10.5281/zenodo.$RECORD)"
