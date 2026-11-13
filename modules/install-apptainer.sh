#!/usr/bin/env bash
# Apptainer module, run by the Dockerfile as root when the image is built with it.
# Installs, offline, from the self-contained bundle in $1 (vendor/apptainer/<key>):
#   - the system packages Apptainer needs (debs/: offline apt repository);
#   - Apptainer itself is already extracted in /opt/apptainer by the Dockerfile
#     (ADD), here it is only linked into the PATH.
# If the base image already has Apptainer, it is kept as it is (reinstalling could
# downgrade it and break what the image's authors set up).
set -euo pipefail
BUNDLE="${1:?usage: install-apptainer.sh <bundle folder>}"
export DEBIAN_FRONTEND=noninteractive

if command -v apptainer >/dev/null 2>&1 && [ "$(command -v apptainer)" != /usr/local/bin/apptainer ]; then
  echo "[install-apptainer] the base image already has $(apptainer --version): kept as it is"
  rm -rf /opt/apptainer
  exit 0
fi

# run-time packages from the bundle's own repository only (no internet)
mkdir -p /tmp/apptainer-apt/state/partial
echo "deb [trusted=yes] file:${BUNDLE}/debs ./" > /tmp/apptainer-apt/sources.list
APT_ONLY_BUNDLE=(-o Dir::Etc::sourcelist=/tmp/apptainer-apt/sources.list -o Dir::Etc::sourceparts=-
                 -o Dir::State::Lists=/tmp/apptainer-apt/state -o APT::Get::List-Cleanup=0
                 -o APT::Default-Release=)   # some images set it (e.g. "testing"): unknown to the bundle
apt-get "${APT_ONLY_BUNDLE[@]}" update
apt-get "${APT_ONLY_BUNDLE[@]}" install -y --no-install-recommends --allow-downgrades \
  $(cat "${BUNDLE}/packages.txt")
rm -rf /tmp/apptainer-apt

# the program (extracted by the Dockerfile into /opt/apptainer)
[ -x /opt/apptainer/bin/apptainer ] || { echo "ERROR: /opt/apptainer/bin/apptainer missing" >&2; exit 1; }
for program in /opt/apptainer/bin/*; do
  ln -sf "$program" "/usr/local/bin/$(basename "$program")"
done

# By default Apptainer binds /etc/localtime into its containers and stops if it is
# missing: minimal images (e.g. ubuntu:22.04, no tzdata) do not have it. There the
# rule is turned off (Apptainer containers then use UTC, as the image itself).
CONF=/opt/apptainer/etc/apptainer/apptainer.conf
if [ ! -e /etc/localtime ]; then
  sed -i 's|^bind path = /etc/localtime$|# bind path = /etc/localtime   (JupyDo: this image has no /etc/localtime)|' "$CONF"
fi
apptainer --version
