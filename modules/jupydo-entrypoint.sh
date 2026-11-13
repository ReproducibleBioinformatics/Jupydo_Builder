#!/bin/bash
# JupyDo entrypoint: runs the container's command as the JupyDo user.
#
# JupyDo passes NB_USER (the hub username) and NB_UID (unique per user), so
# every user has their own account and UID: processes and files are
# traceable to the person, also from the host. The account gets passwordless
# sudo. Without NB_USER (e.g. a plain `docker run`), it runs as jovyan.
set -e

NB_USER="${NB_USER:-jovyan}"
NB_UID="${NB_UID:-$(id -u jovyan 2>/dev/null || echo 1000)}"
NB_GID="${NB_GID:-100}"
HOME_DIR="${JUPYDO_HOME:-/home/jovyan}"

# Already started as a non-root user (docker run --user ...): nothing to set up.
if [ "$(id -u)" != "0" ]; then
  exec "$@"
fi

getent group "$NB_GID" >/dev/null || groupadd -g "$NB_GID" jupydo

# Create the account. If the name is taken by an account with another UID
# (e.g. a system user called like the hub user), use a suffixed name instead.
if id "$NB_USER" >/dev/null 2>&1 && [ "$(id -u "$NB_USER")" != "$NB_UID" ]; then
  echo "[jupydo-entrypoint] user '$NB_USER' already exists with another UID, using '${NB_USER}-jd'" >&2
  NB_USER="${NB_USER}-jd"
fi
if ! id "$NB_USER" >/dev/null 2>&1; then
  useradd -o -u "$NB_UID" -g "$NB_GID" -d "$HOME_DIR" -M -s /bin/bash "$NB_USER"
fi

# Home: the user can write only in hidden files and folders (settings, caches,
# packages of programs). Visible files belong in /sharedFolder: anywhere else
# needs sudo, so nothing lands in the wrong place by mistake (e.g. drag and drop).
mkdir -p "$HOME_DIR"
for d in .local .cache .config .jupyter .ipython .conda .R .npm .ssh .virtualenvs .keras .nextflow \
         .apptainer .singularity; do
  mkdir -p "$HOME_DIR/$d"
done
for f in .bash_history .python_history .Rhistory .lesshst .viminfo .wget-hsts .gitconfig \
         .bashrc .profile .Renviron .sudo_as_admin_successful; do
  [ -e "$HOME_DIR/$f" ] || touch "$HOME_DIR/$f"
done
# Everything inside the home belongs to the user (also files coming from a saved
# image of another user, or folders Docker created for mounts); the home itself to root.
if find "$HOME_DIR" -mindepth 1 -maxdepth 2 ! -user "$NB_UID" -print -quit | grep -q .; then
  echo "[jupydo-entrypoint] fixing ownership inside $HOME_DIR for $NB_USER ($NB_UID)" >&2
  find "$HOME_DIR" -mindepth 1 ! -user "$NB_UID" -exec chown -h "$NB_UID:$NB_GID" {} + 2>/dev/null || true
fi
chown root:root "$HOME_DIR"
chmod 755 "$HOME_DIR"

if command -v sudo >/dev/null 2>&1; then
  mkdir -p /etc/sudoers.d
  echo "$NB_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/jupydo-user
  chmod 440 /etc/sudoers.d/jupydo-user
else
  echo "[jupydo-entrypoint] WARNING: sudo is not installed in this image" >&2
fi

# JUPYDO_SETUP_ONLY=1: prepare the account and stop here, without switching user
# (used by the builder's tests to check the account alone)
if [ "${JUPYDO_SETUP_ONLY:-0}" = "1" ]; then
  echo "[jupydo-entrypoint] account ${NB_USER} (${NB_UID}) ready" >&2
  exit 0
fi

export HOME="$HOME_DIR" USER="$NB_USER" LOGNAME="$NB_USER" SHELL=/bin/bash
export LD_LIBRARY_PATH=/usr/local/lib/R/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}
# Switch to the user with setpriv (util-linux: in every Ubuntu/Debian image, written
# in C): unlike gosu (Go) it also works under QEMU emulation (arm64 images on an
# amd64 server and vice versa). gosu stays as a fallback for images without it.
if command -v setpriv >/dev/null 2>&1; then
  exec setpriv --reuid="$NB_UID" --regid="$NB_GID" --init-groups "$@"
fi
exec gosu "$NB_USER" "$@"
