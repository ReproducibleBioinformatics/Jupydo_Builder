#!/usr/bin/env bash
# Pins every image of lists/test-images.txt to its digest (image:tag@sha256:...):
# the tests then always run on exactly the same images, whatever happens to the
# tag later (":latest" and even version tags are rebuilt by their publishers).
# The tag stays in the line, only to be readable: Docker uses the digest.
# Usage (from the builder folder):
#   scripts/pin-test-images.sh            pin the images not pinned yet
#   scripts/pin-test-images.sh --update   resolve every tag again (new digests)
# Needs network access to the registries (docker buildx imagetools).
set -euo pipefail
cd "$(dirname "$0")/.."
LIST=lists/test-images.txt
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
changed=0
while IFS= read -r line || [ -n "$line" ]; do
  first="$(printf '%s\n' "$line" | sed 's/#.*//' | awk '{print $1}')"
  if [ -z "$first" ] || { [[ "$first" == *@sha256:* ]] && [ "$UPDATE" = 0 ]; }; then
    printf '%s\n' "$line" >> "$TMP"
    continue
  fi
  ref="${first%@*}"
  digest="$(docker buildx imagetools inspect "$ref" --format '{{.Manifest.Digest}}')" \
    || { echo "ERROR: cannot resolve ${ref} (nothing changed in ${LIST})" >&2; exit 1; }
  new="${ref}@${digest}"
  if [ "$new" != "$first" ]; then
    echo "${ref} -> ${digest}"
    changed=$((changed + 1))
  fi
  printf '%s\n' "${line/"$first"/"$new"}" >> "$TMP"
done < "$LIST"
cp "$TMP" "$LIST"
echo "${changed} image(s) pinned in ${LIST}"
