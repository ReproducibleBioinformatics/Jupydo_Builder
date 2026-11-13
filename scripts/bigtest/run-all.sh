#!/usr/bin/env bash
# Large-scale test on THIS machine, for both architectures:
#   1. the list of this machine's architecture, natively
#   2. the list of the other architecture, in emulation (QEMU)
# Run it on an amd64 machine and on an arm64 machine: the four results together are
# the two lists x the two machines. Each part goes to its own folder,
#   tests/bigtest-<list arch>-on-<machine arch>/big-results.tsv
# and can be stopped and started again (it goes on where it stopped; NETWORK rows are
# tried again).
# Usage (from the builder folder):
#   scripts/bigtest/run-all.sh <amd64 list> <arm64 list>
#   EMULATED_LIMIT=200 scripts/bigtest/run-all.sh ...   only the first 200 images of the
#                                                       emulated part (default: all; emulation
#                                                       is several times slower)
#   ONLY=native | ONLY=emulated                          only one of the two parts
set -uo pipefail
cd "$(dirname "$0")/../.."
AMD64_LIST="${1:?usage: scripts/bigtest/run-all.sh <amd64 list> <arm64 list>}"
ARM64_LIST="${2:?usage: scripts/bigtest/run-all.sh <amd64 list> <arm64 list>}"
host="$(docker info --format '{{.Architecture}}' 2>/dev/null | sed 's/x86_64/amd64/; s/aarch64/arm64/')"
case "$host" in amd64) other=arm64 ;; arm64) other=amd64 ;; *) echo "unknown machine architecture: $host" >&2; exit 1 ;; esac
list_for() { [ "$1" = amd64 ] && echo "$AMD64_LIST" || echo "$ARM64_LIST"; }

run() {  # $1 = list architecture, $2 = limit
  local dir="tests/bigtest-$1-on-${host}"
  echo; echo "################ $1 list on this $host machine$([ "$1" != "$host" ] && echo ' (emulated)') -> $dir"
  LIST="$(list_for "$1")" RUN_DIR="$dir" BIG_ARCH="$1" LIMIT="$2" scripts/test-all.sh big
}

[ "${ONLY:-}" = emulated ] || run "$host" 0
[ "${ONLY:-}" = native ] || run "$other" "${EMULATED_LIMIT:-0}"

echo; echo "################ summary"
for d in "tests/bigtest-${host}-on-${host}" "tests/bigtest-${other}-on-${host}"; do
  [ -f "$d/big-results.tsv" ] || continue
  echo "== $d"
  awk -F'\t' 'NR > 1 {c[$1 " " $4]++} END {for (k in c) print "  " k ": " c[k]}' "$d/big-results.tsv" | sort
done
