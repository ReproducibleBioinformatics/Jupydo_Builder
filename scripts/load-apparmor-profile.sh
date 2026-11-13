#!/usr/bin/env bash
# Installs and loads the AppArmor profile "jupydo-apptainer" (security/
# jupydo-apptainer.apparmor.in), used only by containers with the Apptainer module.
# Adapts it to this machine's AppArmor (the userns rule exists from AppArmor 4 / abi
# 4.0 on), puts it in /etc/apparmor.d (reloaded automatically at every boot) and
# loads it now. Run as root; JupyDo's first_start.sh runs it.
# Machines without AppArmor: nothing to do (Docker then needs no profile).
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" != "Y" ] || ! command -v apparmor_parser >/dev/null 2>&1; then
  echo "AppArmor not active on this machine: no profile needed."
  exit 0
fi
if [ -f /etc/apparmor.d/abi/4.0 ]; then
  ABI='abi <abi/4.0>,'; USERNS='userns,'
else
  ABI=''; USERNS=''   # AppArmor 3: no user-namespace ban to lift
fi
sed -e "s#@ABI@#${ABI}#" -e "s#@USERNS@#${USERNS}#" security/jupydo-apptainer.apparmor.in > /etc/apparmor.d/jupydo-apptainer
apparmor_parser -r -W /etc/apparmor.d/jupydo-apptainer
echo "AppArmor profile jupydo-apptainer loaded ($( [ -n "$USERNS" ] && echo 'AppArmor 4: user namespaces allowed for it' || echo 'AppArmor 3' ))."
