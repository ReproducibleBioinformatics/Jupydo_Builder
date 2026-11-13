#!/usr/bin/env bash
# Version of the JupyDo stack for one image: a hash of the Dockerfile, the modules
# (install and runtime scripts) and the checksums of the bundles that image uses.
# The lists/ files are not part of it: what they produce is already in the bundles'
# checksums, so adding a distribution or an exception does not change the version
# of the images that do not use it.
# Stored in the image label org.jupydo.builder: an image is rebuilt only when this changes.
# Usage: builder-version.sh <distro-version-arch> <arch> [module ...]
#   e.g. builder-version.sh ubuntu-24.04-amd64 amd64 apptainer
# PYTHON_BUNDLE=python-legacy for images using the legacy Python bundle (default: python);
# KERNEL_LIBS="cp312 cp314": kernel libraries the image uses (the Python versions it has).
set -euo pipefail
cd "$(dirname "$0")/../.."
KEY="$1"; ARCH="$2"; shift 2; MODULES=("$@")
{
  sha256sum Dockerfile modules/*
  sha256sum "vendor/apt/${KEY}/debs/SHA256SUMS" "vendor/${PYTHON_BUNDLE:-python}/${ARCH}/SHA256SUMS" vendor/r/snapshots.txt vendor/r/*/SHA256SUMS
  for tag in ${KERNEL_LIBS:-}; do   # kernel libraries of the Python versions the image has
    sha256sum "vendor/kernel-libs/${ARCH}/${tag}/SHA256SUMS"
  done
  for module in "${MODULES[@]}"; do
    sha256sum "vendor/${module}/${KEY}/SHA256SUMS"
  done
} | sha256sum | cut -c1-12
