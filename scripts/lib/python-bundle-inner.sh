#!/usr/bin/env bash
# Runs INSIDE ubuntu:20.04 (glibc 2.31; ubuntu:16.04, glibc 2.23, for the legacy
# bundle), as root, for one architecture. Builds /opt/python4Jup: the portable Python + exactly the packages
# of python-requirements.lock (hashes checked), and packs it.
# pip, running on the oldest glibc, picks binary wheels that also work on every
# newer distribution: one bundle per architecture serves Ubuntu and Debian.
# Inputs (environment): PYTHON_TGZ (portable Python archive), LOCK (lock file),
#                       OUT_DIR, EXPECTED_ARCH, HOST_UID/HOST_GID (optional).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
PREFIX=/opt/python4Jup

ARCH="$(dpkg --print-architecture)"
[ "$ARCH" = "$EXPECTED_ARCH" ] || { echo "ERROR: expected ${EXPECTED_ARCH}, found ${ARCH}" >&2; exit 1; }

rm -rf "$OUT_DIR" "$PREFIX"
mkdir -p "$OUT_DIR" /opt
# the archive contains python/: it becomes /opt/python4Jup
tar -xzf "$PYTHON_TGZ" -C /opt
mv /opt/python "$PREFIX"

# certificates for pip (the archive does not use the system ones by itself)
apt-get update -qq && apt-get install -y -qq --no-install-recommends ca-certificates > /dev/null

"$PREFIX/bin/python3" -m pip install --no-cache-dir --disable-pip-version-check \
  --require-hashes --only-binary=:all: --no-deps -r "$LOCK" > "$OUT_DIR/pip-install.log" 2>&1 \
  || { tail -30 "$OUT_DIR/pip-install.log" >&2; exit 1; }

# The default "Python 3" kernel, pointing to this Python (absolute path)
"$PREFIX/bin/python3" -m ipykernel install --prefix "$PREFIX" --name python3 \
  --display-name "Python 3 (ipykernel)" > /dev/null

# Self-test: the programs JupyDo starts must work
"$PREFIX/bin/python3" -m pip check
"$PREFIX/bin/jupyterhub-singleuser" --version > /dev/null
"$PREFIX/bin/jupyter-lab" --version > /dev/null
"$PREFIX/bin/jupyter" kernelspec list | grep -q python3

"$PREFIX/bin/python3" -m pip freeze --all > "$OUT_DIR/versions.txt"
{
  echo "python=$("$PREFIX/bin/python3" -c 'import platform; print(platform.python_version())')"
  echo "architecture=${ARCH}"
  echo "jupyterhub=$("$PREFIX/bin/jupyterhub-singleuser" --version 2>/dev/null | tail -1)"
  echo "jupyterlab=$("$PREFIX/bin/jupyter-lab" --version)"
  echo "packages=$(grep -c '==' "$OUT_DIR/versions.txt")"
  echo "built_on=$(. /etc/os-release; echo "${ID}-${VERSION_ID}") (glibc $(ldd --version | head -1 | awk '{print $NF}'))"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$OUT_DIR/manifest.txt"

tar -czf "$OUT_DIR/python4jup.tar.gz" -C /opt python4Jup
(cd "$OUT_DIR" && sha256sum python4jup.tar.gz > SHA256SUMS)
touch "$OUT_DIR/.complete"
if [ -n "${HOST_UID:-}" ]; then chown -R "${HOST_UID}:${HOST_GID:-$HOST_UID}" "$OUT_DIR"; fi
echo "OK python ${ARCH}: $(grep '^packages=' "$OUT_DIR/manifest.txt" | cut -d= -f2) packages, $(du -sh "$OUT_DIR/python4jup.tar.gz" | cut -f1)"
