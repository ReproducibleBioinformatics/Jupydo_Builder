#!/bin/sh
# Run by the Dockerfile as root after every step that installs packages. Installing
# packages rebuilds the library index (ldconfig): a library the image keeps in a
# folder listed BEFORE the system's (e.g. an old libstdc++ in /usr/local/lib, which
# the image's own index did not include) can then replace the system's one for the
# system's programs, and apt stops working ("GLIBCXX_3.4.29 not found").
# Only if apt worked in the ORIGINAL image and does not now: the system's library
# folders are listed first, the index rebuilt, and this is kept only if apt works
# again (noted in /opt/jupydo/ld-paths.txt, shown by jupydo-check). Nothing of the
# image is removed or moved; libraries only the image has are still found.
CONF=/etc/ld.so.conf.d/000-jupydo-system-first.conf
[ -f /opt/jupydo/apt-worked ] || exit 0
apt-get --version >/dev/null 2>&1 && exit 0
[ -f "$CONF" ] && exit 0
# the system's multiarch folder name (x86_64-linux-gnu, aarch64-linux-gnu): from the
# system's own ld.so.conf.d file, else from dpkg (no compiler needed)
ma="$(ls /etc/ld.so.conf.d/ 2>/dev/null | sed -n 's/^\([a-z0-9_]*-linux-gnu[a-z]*\)\.conf$/\1/p' | head -1)"
if [ -z "$ma" ]; then
  case "$(dpkg --print-architecture 2>/dev/null)" in
    amd64) ma=x86_64-linux-gnu ;; arm64) ma=aarch64-linux-gnu ;;
  esac
fi
[ -n "$ma" ] || exit 0
printf '/lib/%s\n/usr/lib/%s\n' "$ma" "$ma" > "$CONF"
ldconfig
if apt-get --version >/dev/null 2>&1; then
  msg="system library folders listed first (a library of the image in a folder listed before them broke apt): $CONF"
  echo "$msg" >> /opt/jupydo/ld-paths.txt
  echo "JupyDo: $msg" >&2
else
  rm -f "$CONF"; ldconfig
  echo "JupyDo: apt does not work after installing packages, and listing the system libraries first does not help" >&2
fi
