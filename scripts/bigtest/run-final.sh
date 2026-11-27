#!/usr/bin/env bash
# The final large-scale test, exactly as it was run for the paper: the same lists, the
# same split over the machines, the same parameters. Three roles, one per machine (one
# amd64 machine and two arm64 ones were used; the roles can also run on fewer machines,
# one after the other):
#   amd64    the amd64 list natively, in 4 parts at the same time (lists/bigtest/
#            amd64-part0..3.tsv), and the arm64 list in emulation
#   arm64-a  the arm64 list natively, then the first half of the amd64 list in emulation
#            (lists/bigtest/amd64-half1.tsv)
#   arm64-b  the second half of the amd64 list in emulation (lists/bigtest/amd64-half2.tsv)
# Each part runs in its own tmux session (big0..big3 and big-arm, or big) and writes
#   tests/bigtest-<list arch>-on-<machine arch>[-partN|-halfN]/big-results.tsv
# with the build log of each image in logs/ and the machine's description in
# environment.txt. A part can be stopped and started again: it goes on where it stopped.
# Before: sudo scripts/setup-host.sh (Docker, the same QEMU on every machine, AppArmor)
# and scripts/get-vendor.sh (the bundles from Zenodo). Summary while it runs:
#   for f in tests/bigtest-*/big-results.tsv; do echo "$f: $(($(wc -l < "$f") - 1))"; done
# Usage (from the builder folder):  scripts/bigtest/run-final.sh amd64|arm64-a|arm64-b
set -euo pipefail
cd "$(dirname "$0")/../.."
ROLE="${1:?usage: scripts/bigtest/run-final.sh amd64|arm64-a|arm64-b}"
L=lists/bigtest
AMD64="$L/bigtest-2026-10-27-amd64.tsv"
ARM64="$L/bigtest-2026-10-27-arm64.tsv"
host="$(docker info --format '{{.Architecture}}' 2>/dev/null | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
case "$ROLE" in
  amd64) want=amd64; other=aarch64 ;;
  arm64-a|arm64-b) want=arm64; other=x86_64 ;;
  *) echo "ERROR: unknown role $ROLE (amd64, arm64-a, arm64-b)" >&2; exit 1 ;;
esac
[ "$host" = "$want" ] || { echo "ERROR: role $ROLE needs an $want machine, this one is $host" >&2; exit 1; }
[ -f vendor/.zenodo-record ] || { echo "ERROR: no bundles: run scripts/get-vendor.sh first" >&2; exit 1; }
command -v tmux >/dev/null || { echo "ERROR: tmux is not installed" >&2; exit 1; }
# the emulator must be the builder's (setup-host.sh), not the distribution's
interp="$(sed -n 's/^interpreter //p' "/proc/sys/fs/binfmt_misc/qemu-$other" 2>/dev/null || true)"
case "$interp" in
  "") echo "ERROR: no QEMU for $other: run sudo scripts/setup-host.sh first" >&2; exit 1 ;;
  /usr/libexec/qemu-binfmt/*) echo "ERROR: the distribution's QEMU is registered ($interp): run sudo scripts/setup-host.sh" >&2; exit 1 ;;
esac

environment() {  # $1 = run folder: what this machine is, for the record
  mkdir -p "$1"
  {
    echo "date: $(date -Is)"
    echo "role: $ROLE"
    echo "builder: $(git rev-parse HEAD 2>/dev/null)$(git diff --quiet 2>/dev/null || echo ' (modified)')"
    echo "bundles: Zenodo record $(cat vendor/.zenodo-record)"
    echo "machine: $(uname -m), $(nproc) threads, $(awk '/MemTotal/ {printf "%.0f GB", $2/1048576}' /proc/meminfo)"
    echo "cpu: $(lscpu 2>/dev/null | sed -n 's/^Model name: *//p' | head -1)"
    echo "system: $(. /etc/os-release && echo "$PRETTY_NAME"), kernel $(uname -r)"
    echo "docker: $(docker version --format '{{.Server.Version}}'), storage $(docker info --format '{{.Driver}}')"
    echo "qemu-$other: $(head -3 "/proc/sys/fs/binfmt_misc/qemu-$other" | tr '\n' ' ')"
  } > "$1/environment.txt"
}

start() {  # start <session> <list> <list arch> <run folder> [KEEP_CACHE=...]
  environment "$4"
  tmux new -d -s "$1" "${5:-} LIST=$2 RUN_DIR=$4 BIG_ARCH=$3 scripts/test-all.sh big; bash"
  echo "started $1: $2 ($3) -> $4"
}

case "$ROLE" in
  amd64)
    # (a shared server: Docker's build cache, common to all its users, is pruned only
    # above 500 GB; the arm64 machines keep test-all.sh's default)
    for i in 0 1 2 3; do start "big$i" "$L/amd64-part$i.tsv" amd64 "tests/bigtest-amd64-on-amd64-part$i" KEEP_CACHE=500GB; done
    start big-arm "$ARM64" arm64 tests/bigtest-arm64-on-amd64 KEEP_CACHE=500GB ;;
  arm64-a)
    environment tests/bigtest-arm64-on-arm64
    environment tests/bigtest-amd64-on-arm64-half1
    tmux new -d -s big "LIST=$ARM64 RUN_DIR=tests/bigtest-arm64-on-arm64 BIG_ARCH=arm64 scripts/test-all.sh big; LIST=$L/amd64-half1.tsv RUN_DIR=tests/bigtest-amd64-on-arm64-half1 BIG_ARCH=amd64 scripts/test-all.sh big; bash"
    echo "started big: $ARM64 (arm64), then $L/amd64-half1.tsv (amd64, emulated)" ;;
  arm64-b)
    start big "$L/amd64-half2.tsv" amd64 tests/bigtest-amd64-on-arm64-half2 ;;
esac
echo "follow with: tmux attach -t <session>   (detach: Ctrl-b d)"
