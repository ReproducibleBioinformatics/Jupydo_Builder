#!/bin/sh
# Run by the builder (scripts/build-image.sh, JupyDo) inside the ORIGINAL image,
# before anything of JupyDo is added: what the image is, and which Pythons and Rs
# its authors put in it (they become the Jupyter kernels of the environment).
# POSIX sh only (the image may have no bash). Output, one item per line:
#   OS <id> <version> <arch> <glibc>
#   PY <path> <major.minor>        every Python 3 of the image, once (same file = once)
#   R  <path> <version>            every R of the image, once
#   CONDA_ONLY /usr/local <arch>   no dpkg, but a conda environment in /usr/local
#                                  (BioContainers on a BusyBox base): convertible
# An R_HOME set by the image is for one of its Rs: any other R would print a warning
# ("ignoring environment value of R_HOME") in place of its version
unset R_HOME
. /etc/os-release 2>/dev/null
echo "OS ${ID:-unknown} ${VERSION_ID:-none} $(dpkg --print-architecture 2>/dev/null || echo unknown) $(getconf GNU_LIBC_VERSION 2>/dev/null | cut -d' ' -f2)"
# (BusyBox has its own small "dpkg": what counts is that the real one answers)
if ! dpkg --print-architecture >/dev/null 2>&1 && [ -d /usr/local/conda-meta ]; then
  case "$(uname -m)" in x86_64) a=amd64 ;; aarch64) a=arm64 ;; *) a="$(uname -m)" ;; esac
  echo "CONDA_ONLY /usr/local $a"
fi

seen=" "
once() {  # true the first time a real file is seen
  real=$(readlink -f "$1" 2>/dev/null || echo "$1")
  case "$seen" in *" $real "*) return 1 ;; esac
  seen="$seen$real "
  return 0
}

# Pythons: system, /usr/local (official python images), conda/mamba/other in /opt
# and their environments
for p in /usr/bin/python3 /usr/local/bin/python3 \
         /opt/*/bin/python3 /opt/*/bin/python /opt/*/envs/*/bin/python3 /opt/*/envs/*/bin/python \
         /usr/local/*/bin/python3; do
  [ -x "$p" ] || continue
  case "$p" in /opt/python4Jup/*) continue ;; esac   # JupyDo's own (rebuilding a JupyDo image)
  v=$("$p" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null) || continue
  once "$p" || continue
  echo "PY $p $v"
done

# Rs: system, /usr/local (rocker), /opt/R/<version> (Posit), conda and its environments
for r in /usr/bin/R /usr/local/bin/R /opt/R/*/bin/R /opt/*/bin/R /opt/*/envs/*/bin/R; do
  [ -x "$r" ] || continue
  # ask R itself: for R-devel the first line of --version is "R Under development ..."
  v=$("$r" --slave -e 'cat(as.character(getRversion()))' 2>/dev/null)
  [ -n "$v" ] || continue
  once "$r" || continue
  echo "R $r $v"
done
