#!/bin/bash
# Runs as root inside a JupyDo image (NB_USER=jdtest, NB_UID=10999 in the environment).
# Does what JupyDo does at every start (the entrypoint creates the personal account
# and gives it sudo), then checks the result.
#   real    sudo is executed by the user (native architecture)
#   static  under QEMU emulation, where setuid programs (sudo) cannot run and gosu
#           is unreliable: the entrypoint only prepares the account, then the
#           result is checked as root (account, UID, home, sudo setuid bit + rule)
set -e
mode="${1:-real}"
if [ "$mode" = real ]; then
  /usr/local/bin/jupydo-entrypoint bash -c 'test "$(id -un):$(id -u)" = jdtest:10999 && sudo -n true'
else
  JUPYDO_SETUP_ONLY=1 /usr/local/bin/jupydo-entrypoint
  test "$(id -u jdtest)" = 10999
  test "$(stat -c %u "${JUPYDO_HOME:-/home/jovyan}/.local")" = 10999
  test -u "$(command -v sudo)"
  grep -q '^jdtest ALL=(ALL) NOPASSWD:ALL' /etc/sudoers.d/jupydo-user
fi
echo USER_OK
