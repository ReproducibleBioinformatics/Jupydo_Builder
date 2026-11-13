#!/usr/bin/env bash
# Builds the JupyDo version of any Ubuntu/Debian image, offline, from the vendor
# bundles. Detects the distribution and architecture of the base image and puts
# in the build context only the bundles it needs.
#
# Usage (from the builder folder):
#   scripts/build-image.sh <base image> [tag]
# Examples:
#   scripts/build-image.sh rocker/r-ver:4.4.1
#   scripts/build-image.sh ubuntu:24.04 jupydo/test:latest
# Default tag: jupydo/<base image name>:<base tag> (as JupyDo names them).
# PLATFORM=linux/arm64 builds another architecture (needs QEMU on an amd64 machine).
# MODULES="apptainer" adds optional modules: the tag gets "-apptainer" at the end.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
BASE="${1:?usage: scripts/build-image.sh <base image> [tag]}"

# ---- distribution and architecture of the base image
PLATFORM_ARGS=()
if [ -n "${CONVERTED_FROM:-}" ]; then
  [ -z "${PLATFORM:-}" ] || PLATFORM_ARGS=(--platform "$PLATFORM")  # converted here: local only
elif [ -n "${PLATFORM:-}" ]; then
  PLATFORM_ARGS=(--platform "$PLATFORM")
  docker pull --quiet "${PLATFORM_ARGS[@]}" "$BASE" >/dev/null
else
  docker image inspect "$BASE" >/dev/null 2>&1 || docker pull --quiet "$BASE" >/dev/null
fi
# What the ORIGINAL image is, and which Pythons and Rs it has (modules/detect-image.sh)
DETECT_ERR="$(mktemp)"
if ! DETECTED="$(docker run --rm "${PLATFORM_ARGS[@]}" --entrypoint /bin/sh "$BASE" -c "$(cat modules/detect-image.sh)" 2>"$DETECT_ERR")"; then
  if grep -q "does not provide the specified platform" "$DETECT_ERR"; then
    echo "ERROR: $BASE has no ${PLATFORM} version (it is published for other architectures only): not supported on ${PLATFORM}" >&2
  else
    cat "$DETECT_ERR" >&2
    echo "ERROR: cannot run /bin/sh in $BASE: not supported" >&2
  fi
  rm -f "$DETECT_ERR"; exit 1
fi
rm -f "$DETECT_ERR"

# ---- minimal image whose software is a conda environment in /usr/local, with no
# package manager (BioContainers on BusyBox): its /usr/local is moved onto the
# vendored Debian 12 base (Dockerfile.convert), then that image is built as usual.
CONDA_ARCH="$(echo "$DETECTED" | awk '$1 == "CONDA_ONLY" {print $3}')"
if [ -n "$CONDA_ARCH" ]; then
  [ -z "${CONVERTED_FROM:-}" ] \
    || { echo "ERROR: the conversion of ${CONVERTED_FROM} did not give a supported image" >&2; exit 1; }
  CBASE_KEY="$(grep -v '^\s*#' lists/convert-bases.txt | grep -v '^\s*$' | head -1 | tr ':' '-')-${CONDA_ARCH}"
  CBASE_DIR="vendor/bases/${CBASE_KEY}"
  [ -f "${CBASE_DIR}/.complete" ] || { echo "ERROR: missing bundle: ${CBASE_DIR} (scripts/make-vendor-bases.sh):" \
    "minimal images with conda in /usr/local are not supported without it" >&2; exit 1; }
  CBASE_TAG="$(awk '$1 == "tag" {print $2}' "${CBASE_DIR}/manifest.txt")"
  docker image inspect "$CBASE_TAG" >/dev/null 2>&1 || docker load --quiet -i "${CBASE_DIR}/image.tar" >/dev/null
  # the final image keeps the name it would have had from the original image
  OUT_TAG="${2:-}"
  if [ -z "$OUT_TAG" ]; then
    ref="${BASE%@*}"
    if [[ "${ref##*/}" == *:* ]]; then name="${ref%:*}"; tag="${ref##*:}"; else name="$ref"; tag=latest; fi
    OUT_TAG="jupydo/$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g'):${tag}"
    for module in $(printf '%s\n' ${MODULES:-} | sort); do OUT_TAG="${OUT_TAG}-${module}"; done
  fi
  CONV_TAG="jupydo-converted/$(echo "${BASE%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g'):${CONDA_ARCH}"
  echo "Minimal image ${BASE}: no package manager, conda environment in /usr/local:" \
       "moving it onto ${CBASE_KEY}"
  CONV_CTX="$(mktemp -d)"
  cp Dockerfile.convert "${CONV_CTX}/Dockerfile"
  # the variables of the original image (PATH, and those its tools need)
  docker image inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$BASE" | while IFS= read -r kv; do
    [ -n "$kv" ] || continue
    printf 'ENV %s="%s"\n' "${kv%%=*}" "$(printf '%s' "${kv#*=}" | sed 's/[\\"$]/\\&/g')"
  done >> "${CONV_CTX}/Dockerfile"
  echo "LABEL org.jupydo.converted-from=\"${BASE}\" org.jupydo.converted-base=\"${CBASE_KEY}\"" >> "${CONV_CTX}/Dockerfile"
  if ! docker build --quiet --platform "linux/${CONDA_ARCH}" --build-arg TOOL_IMAGE="$BASE" \
       --build-arg CONVERT_BASE="$CBASE_TAG" -t "$CONV_TAG" "$CONV_CTX" >/dev/null; then
    rm -rf "$CONV_CTX"; echo "ERROR: conversion of ${BASE} failed" >&2; exit 1
  fi
  rm -rf "$CONV_CTX"
  CONVERTED_FROM="$BASE" exec "$0" "$CONV_TAG" "$OUT_TAG"
fi

read -r _ ID VERSION ARCH GLIBC <<< "$(echo "$DETECTED" | grep '^OS ')"
[ "${ARCH:-unknown}" != unknown ] \
  || { echo "ERROR: cannot read /etc/os-release + dpkg in $BASE (not Ubuntu/Debian?): not supported" >&2; exit 1; }
KEY="${ID}-${VERSION}-${ARCH}"
echo "Base image: ${BASE} -> ${KEY} (glibc ${GLIBC:-?})"
echo "$DETECTED" | { grep -E '^(PY|R) ' || echo "none (no Python or R in this image)"; } | sed 's/^/  found: /'
# kernel libraries needed: one set per Python version found (cp3XY)
KERNEL_LIBS=()
for v in $(echo "$DETECTED" | awk '$1 == "PY" {print $3}' | sort -u); do
  tag="cp${v/./}"
  if [ -f "vendor/kernel-libs/${ARCH}/${tag}/.complete" ]; then KERNEL_LIBS+=("$tag")
  else echo "  note: no kernel libraries for Python ${v} (${ARCH}): a Python ${v} without ipykernel will not be a kernel"; fi
done
# Python bundle by the image's glibc: current, or legacy for old distributions
PY_BUNDLE="$(scripts/lib/pick-python.sh "$ARCH" "${GLIBC:-0}")" || exit 1
echo "Python bundle: ${PY_BUNDLE}"

APT_DIR="vendor/apt/${KEY}"
# Bundles are frozen: a newer apt bundle for the same system is ADDED next to the old
# one, as <key>-<date> (scripts/make-vendor-apt.sh with NEW=1). The oldest bundle that
# is not behind the image is used (no package of the image newer than the bundle's
# version of it): an image keeps the bundle it always had, and one updated after it
# gets a newer bundle instead of having its packages stepped back.
APT_CANDIDATES=()
for d in "vendor/apt/${KEY}" vendor/apt/"${KEY}"-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]; do
  [ -f "$d/.complete" ] && APT_CANDIDATES+=("$d")
done
if [ "${#APT_CANDIDATES[@]}" -gt 1 ]; then
  APT_DIR="${APT_CANDIDATES[-1]}"   # newer than every bundle: the newest
  for d in "${APT_CANDIDATES[@]}"; do
    # compared inside the image, with its own dpkg (same rules as apt)
    newer="$(docker run --rm -i "${PLATFORM_ARGS[@]}" --entrypoint /bin/sh "$BASE" -c '
      dpkg-query -W -f "\${Package}\t\${Version}\n" > /tmp/jupydo-image-packages 2>/dev/null
      awk -F "\t" "NR == FNR {b[\$1] = \$2; next} (\$1 in b) && \$2 != b[\$1] {print \$1, \$2, b[\$1]}" \
        - /tmp/jupydo-image-packages |
      while read -r p iv bv; do
        if dpkg --compare-versions "$iv" gt "$bv"; then echo "$p $iv (bundle $bv)"; break; fi
      done' < "$d/versions.tsv")"
    if [ -z "$newer" ]; then APT_DIR="$d"; break; fi
    echo "  apt bundle $(basename "$d") is behind this image: ${newer}"
  done
fi
echo "apt bundle: $(basename "$APT_DIR")"
PY_DIR="vendor/${PY_BUNDLE}/${ARCH}"
read -r -a MODULE_LIST <<< "${MODULES:-}"
MODULE_DIRS=()
for module in "${MODULE_LIST[@]}"; do
  [ -f "modules/install-${module}.sh" ] || { echo "ERROR: unknown module ${module}" >&2; exit 1; }
  # a module exists only for the platforms it has a bundle for (e.g. no Apptainer
  # on Ubuntu 16.04/18.04): any other platform is refused with the list
  [ -e "vendor/${module}/${KEY}/.complete" ] || { echo "ERROR: module ${module} is not available for ${KEY}" \
    "(available for: $(ls vendor/"${module}" 2>/dev/null | tr '\n' ' ')): not supported" >&2; exit 1; }
  MODULE_DIRS+=("vendor/${module}/${KEY}/.complete")
done
for need in "$APT_DIR/.complete" "$PY_DIR/.complete" "vendor/r/snapshots.txt" "${MODULE_DIRS[@]}"; do
  [ -e "$need" ] || { echo "ERROR: missing bundle: ${need%/.complete} (supported: $(ls vendor/apt 2>/dev/null | tr '\n' ' '))" >&2; exit 1; }
done

# ---- builder version: changes when the Dockerfile, the modules, the lists or the
# bundles THIS image uses change (rebuilding another distro's bundle does not count)
BUILDER_VERSION="$(PYTHON_BUNDLE="$PY_BUNDLE" KERNEL_LIBS="${KERNEL_LIBS[*]}" \
  scripts/lib/builder-version.sh "$KEY" "$ARCH" "${MODULE_LIST[@]}")"

# ---- tag: jupyter/r-notebook:latest -> jupydo/jupyter-r-notebook:latest
if [ -n "${2:-}" ]; then
  TAG="$2"
else
  ref="${BASE%@*}"   # without the digest, if pinned (image:tag@sha256:...)
  if [[ "${ref##*/}" == *:* ]]; then name="${ref%:*}"; tag="${ref##*:}"; else name="$ref"; tag=latest; fi
  TAG="jupydo/$(echo "$name" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g'):${tag}"
  for module in $(printf '%s\n' "${MODULE_LIST[@]}" | sort); do TAG="${TAG}-${module}"; done
fi

# ---- minimal build context (hard links when possible: no copy of the bundles)
CTX="${ROOT}/.build-context"
rm -rf "$CTX"; mkdir -p "$CTX/selected"
trap 'rm -rf "$CTX"' EXIT
cp Dockerfile "$CTX/"
cp -r modules "$CTX/"
cp -al "$APT_DIR" "$CTX/selected/apt" 2>/dev/null || cp -a "$APT_DIR" "$CTX/selected/apt"
mkdir -p "$CTX/selected/python"
ln "$PY_DIR/python4jup.tar.gz" "$CTX/selected/python/" 2>/dev/null || cp "$PY_DIR/python4jup.tar.gz" "$CTX/selected/python/"
cp -al vendor/r "$CTX/selected/r" 2>/dev/null || cp -a vendor/r "$CTX/selected/r"
# modules: their packages in selected/modules/<name>, Apptainer's program as an archive
# for ADD (an empty archive when the module is off)
mkdir -p "$CTX/selected/modules"
tar -czf "$CTX/selected/apptainer.tar.gz" -T /dev/null
# the Pythons and Rs found, and the kernel libraries for their versions (may be empty)
echo "$DETECTED" > "$CTX/selected/kernels.txt"
if [ "${#KERNEL_LIBS[@]}" -gt 0 ]; then
  tar -czf "$CTX/selected/kernel-libs.tar.gz" -C "vendor/kernel-libs/${ARCH}" \
    $(for t in "${KERNEL_LIBS[@]}"; do echo "$t/site $t/manifest.txt"; done)
else
  tar -czf "$CTX/selected/kernel-libs.tar.gz" -T /dev/null
fi
for module in "${MODULE_LIST[@]}"; do
  src="vendor/${module}/${KEY}"
  mkdir -p "$CTX/selected/modules/${module}"
  cp -al "$src/debs" "$CTX/selected/modules/${module}/debs" 2>/dev/null || cp -a "$src/debs" "$CTX/selected/modules/${module}/debs"
  cp "$src/packages.txt" "$CTX/selected/modules/${module}/"
  [ -d "$src/wheels" ] && cp -a "$src/wheels" "$CTX/selected/modules/${module}/wheels"
  if [ -d "$src/files" ]; then  # large files of the module (e.g. code-server): hard links
    cp -al "$src/files" "$CTX/selected/modules/${module}/files" 2>/dev/null || cp -a "$src/files" "$CTX/selected/modules/${module}/files"
  fi
  if [ "$module" = apptainer ]; then
    ln -f "$src/apptainer.tar.gz" "$CTX/selected/apptainer.tar.gz" 2>/dev/null || cp "$src/apptainer.tar.gz" "$CTX/selected/apptainer.tar.gz"
  fi
done

# same labels JupyDo puts: platform + exact base image, so the hub recognises and
# reuses an image built by hand (and rebuilds it if the base image changes)
BASE_ID="$(docker image inspect --format '{{.Id}}' "$BASE")"

echo "Building ${TAG} (builder ${BUILDER_VERSION})"
docker build --platform "linux/${ARCH}" \
  --build-arg BASE_IMAGE="$BASE" --build-arg JUPYDO_BUILDER_VERSION="$BUILDER_VERSION" \
  --build-arg JUPYDO_MODULES="${MODULE_LIST[*]}" \
  --label org.jupydo.platform="$KEY" --label org.jupydo.base_id="$BASE_ID" --label org.jupydo.python="$PY_BUNDLE" \
  --label org.jupydo.kernel_libs="${KERNEL_LIBS[*]}" --label org.jupydo.apt_bundle="$(basename "$APT_DIR")" \
  -t "$TAG" "$CTX"

# Same check JupyDo runs before starting an image (the build output hides it)
echo
echo "=== check of ${TAG} ==="
docker run --rm --platform "linux/${ARCH}" --entrypoint /usr/local/bin/jupydo-check "$TAG"
echo "OK ${TAG}"
