#!/usr/bin/env bash
# Vendors everything needed to BUILD the JupyDo hub image without internet (JupyDo's
# Dockerfile.jupyterhub uses only these files; JupyDo's build-hub.sh stages them):
#
#   vendor/hub/common/          genome-index.tar.gz, assistant.tar.gz (their source at
#                               the commit of their main branch, written in manifest.txt)
#   vendor/hub/<arch>/          amd64 and arm64:
#       base-image.tar.gz         the base image (python:3.9, pinned by digest), as
#                                 jupydo-hub-base:vendored
#       wheels/ requirements.txt  the hub's Python packages and all their dependencies
#       node.tar.xz               Node.js (latest 22.x LTS, checked against nodejs.org's SHASUMS)
#       configurable-http-proxy.tar.gz   JupyterHub's proxy, installed with that Node.js
#
# Each folder gets manifest.txt (versions), SHA256SUMS and .complete. Run on the machine
# that makes the vendor bundles (Docker + QEMU for the other architecture, see
# setup-host.sh); then scripts/publish-zenodo.py puts vendor/hub on Zenodo with the rest.
# Usage: scripts/make-vendor-hub.sh [amd64] [arm64]      (default: both)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=vendor/hub
BASE=python:3.9
NODE_MAJOR=22
CHP_SPEC="configurable-http-proxy@4"
REQUIREMENTS=(
    'jupyterhub==5.5.1'
    'jupyterhub-nativeauthenticator==1.3.0'
    'dockerspawner==14.0.0'
    'flask==3.1.0'
    'waitress==3.0.2'
    'requests==2.32.3'
    'oauthenticator==17.3.0'
)
SOURCES=(   # name  GitHub repository (main branch)
    "genome-index ReproducibleBioinformatics/Index_builderGUI"
    "assistant    ReproducibleBioinformatics/JupyDo-Assistant"
)
ARCHS=("$@")
[ ${#ARCHS[@]} -gt 0 ] || ARCHS=(amd64 arm64)

seal() {   # manifest already written: checksums, then the folder is complete
    (cd "$1" && find . -type f ! -name SHA256SUMS ! -name .complete -print0 | sort -z \
        | xargs -0 sha256sum > SHA256SUMS)
    touch "$1/.complete"
}

# ---- 1. sources of the hub's services (the same for every architecture)
echo "== common: sources of the Genome Index Service and of the JupyDo Assistant"
rm -rf "$OUT/common.partial" && mkdir -p "$OUT/common.partial"
{
    echo "# JupyDo hub: sources vendored by scripts/make-vendor-hub.sh on $(date -u +%F)"
    for s in "${SOURCES[@]}"; do
        read -r name repo <<< "$s"
        sha="$(git ls-remote "https://github.com/$repo" refs/heads/main | cut -f1)"
        [ -n "$sha" ] || { echo "ERROR: cannot read the main branch of $repo" >&2; exit 1; }
        curl -fsSL -o "$OUT/common.partial/$name.tar.gz" "https://github.com/$repo/archive/$sha.tar.gz"
        echo "$name https://github.com/$repo $sha"
        echo "  $name: $repo @ $sha" >&2
    done
} > "$OUT/common.partial/manifest.txt"
seal "$OUT/common.partial"
rm -rf "$OUT/common" && mv "$OUT/common.partial" "$OUT/common"

# ---- 2. Node.js: the latest 22.x LTS today
NODE_VERSION="$(curl -fsSL https://nodejs.org/dist/index.json | python3 -c '
import json, sys
print(next(r["version"] for r in json.load(sys.stdin) if r["version"].startswith("v'"$NODE_MAJOR"'.") and r["lts"]))')"
echo "== Node.js $NODE_VERSION"
NODE_SUMS="$(curl -fsSL "https://nodejs.org/dist/$NODE_VERSION/SHASUMS256.txt")"

# ---- 3. per architecture
for arch in "${ARCHS[@]}"; do
    case "$arch" in
        amd64) node_arch=x64 ;;
        arm64) node_arch=arm64 ;;
        *) echo "ERROR: unknown architecture $arch (amd64 or arm64)" >&2; exit 1 ;;
    esac
    dir="$OUT/$arch.partial"
    echo "== $arch"
    rm -rf "$dir" && mkdir -p "$dir/wheels"

    echo "  base image $BASE"
    docker pull -q --platform "linux/$arch" "$BASE" >/dev/null
    digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$BASE")"
    docker tag "$BASE" jupydo-hub-base:vendored
    docker save jupydo-hub-base:vendored | gzip -1 > "$dir/base-image.tar.gz"

    echo "  Python packages (wheels)"
    printf '%s\n' "${REQUIREMENTS[@]}" > "$dir/requirements.txt"
    docker run --rm --platform "linux/$arch" --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$PWD/$dir:/out" jupydo-hub-base:vendored \
        python3 -m pip wheel -q --no-cache-dir --wheel-dir /out/wheels -r /out/requirements.txt

    echo "  Node.js $NODE_VERSION ($node_arch)"
    node_file="node-$NODE_VERSION-linux-$node_arch.tar.xz"
    curl -fsSL -o "$dir/node.tar.xz" "https://nodejs.org/dist/$NODE_VERSION/$node_file"
    want="$(echo "$NODE_SUMS" | awk -v f="$node_file" '$2 == f {print $1}')"
    [ "$(sha256sum "$dir/node.tar.xz" | cut -d' ' -f1)" = "$want" ] \
        || { echo "ERROR: $node_file does not match nodejs.org's SHASUMS256.txt" >&2; exit 1; }

    echo "  $CHP_SPEC"
    docker run --rm --platform "linux/$arch" --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$PWD/$dir:/out" jupydo-hub-base:vendored sh -ec '
            mkdir -p /tmp/node /tmp/chp
            tar -xJf /out/node.tar.xz -C /tmp/node --strip-components=1
            export PATH=/tmp/node/bin:$PATH
            npm install -g --silent --no-fund --no-audit --cache /tmp/npm --prefix /tmp/chp "'"$CHP_SPEC"'"
            tar -czf /out/configurable-http-proxy.tar.gz -C /tmp/chp .
            /tmp/chp/bin/configurable-http-proxy --version > /out/chp-version.txt'

    {
        echo "# JupyDo hub ($arch): vendored by scripts/make-vendor-hub.sh on $(date -u +%F)"
        echo "base $digest (image $(docker image inspect --format "{{.Id}}" jupydo-hub-base:vendored))"
        echo "node $NODE_VERSION"
        echo "configurable-http-proxy $(cat "$dir/chp-version.txt")"
        echo "# Python packages:"
        (cd "$dir/wheels" && ls *.whl)
    } > "$dir/manifest.txt"
    rm -f "$dir/chp-version.txt"
    seal "$dir"
    rm -rf "${OUT:?}/$arch" && mv "$dir" "$OUT/$arch"
    echo "  done: $OUT/$arch ($(du -sh "$OUT/$arch" | cut -f1))"
done
docker rmi jupydo-hub-base:vendored >/dev/null 2>&1 || true
echo "vendor/hub ready."
