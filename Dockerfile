# JupyDo image = any Ubuntu/Debian base image + the JupyDo stack, installed OFFLINE
# from the vendor bundles. Built by scripts/build-image.sh (or by JupyDo), which puts
# in the build context only the bundles of the base's distribution and architecture:
#   selected/apt      offline apt repository (debs/) + resolved package lists (lists/)
#   selected/python   python4jup.tar.gz -> /opt/python4Jup (JupyterLab, kernels)
#   selected/r        CRAN snapshots for the R kernels + snapshots.txt
#   selected/kernels.txt       the Pythons and Rs of the original image (detect-image.sh)
#   selected/kernel-libs.tar.gz  ipykernel for the Python versions found (may be empty)
#   selected/modules  for each optional module in JUPYDO_MODULES: its own packages
#   selected/apptainer.tar.gz  Apptainer (an empty archive when the module is off)
# always passed by scripts/build-image.sh (or JupyDo); the default only avoids a warning
ARG BASE_IMAGE=ubuntu:24.04
FROM ${BASE_IMAGE}
USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Whether apt works in the ORIGINAL image: a later repair of the library order
# (modules/fix-ld-order.sh, after every step that installs packages) only restores it.
COPY modules/fix-ld-order.sh /usr/local/lib/jupydo/fix-ld-order.sh
RUN mkdir -p /opt/jupydo && if apt-get --version >/dev/null 2>&1; then touch /opt/jupydo/apt-worked; fi

# ---- 0. A conda environment in /usr/local (BioContainers, also those on a full
# Debian base, e.g. for graphical tools): its libraries in /usr/local/lib must not
# replace the system's for the system's own programs. Debian/Ubuntu list
# /usr/local/lib among the system library paths, so dpkg's helpers (e.g.
# dbus-uuidgen) would load conda's copies and fail. Conda programs find their
# libraries through their own RPATH and do not need it: /usr/local/lib is removed
# from the system paths, ONLY when /usr/local is a conda environment (e.g. the
# python:3.x images keep their own libpython there). Debian's file listing it
# (libc.conf) is moved aside with dpkg-divert, so that a later update of libc-bin
# cannot put it back. Listed in /opt/jupydo/ld-paths.txt for the check.
RUN if [ -d /usr/local/conda-meta ] && [ -d /etc/ld.so.conf.d ]; then \
      mkdir -p /opt/jupydo; \
      if [ -f /etc/ld.so.conf.d/libc.conf ] && command -v dpkg-divert >/dev/null; then \
        dpkg-divert --local --rename --divert /etc/ld.so.conf.d/libc.conf.jupydo-off \
          --add /etc/ld.so.conf.d/libc.conf; fi; \
      sed -i '\#^/usr/local/lib$#d' /etc/ld.so.conf /etc/ld.so.conf.d/*.conf 2>/dev/null; \
      ldconfig; \
      echo "/usr/local/lib removed from the system library paths (conda environment in /usr/local)" \
        > /opt/jupydo/ld-paths.txt; \
    fi

# ---- 1. System packages: build tools, libraries, sudo/gosu (lists/apt-base.txt)
# apt uses ONLY the vendor repository (whatever format the image's own sources
# use: sources.list, *.list, *.sources): nothing is downloaded from the internet.
# If the base image is NEWER than the bundle (e.g. libxml2 got a security update
# after the bundle was made), the bundle's -dev packages need the bundle's exact
# library version, and apt never steps back on its own: the first attempt fails.
# Then a second attempt gives the bundle priority (pin 1001), so apt steps back
# ONLY the libraries it needs; packages the image already has are left out of the
# second request (otherwise the pin would step them back too, e.g. sudo, for
# nothing); --no-remove stops the build instead of removing a program of the image. Every step back is listed in /opt/jupydo/apt-downgrades.txt
# and shown as WARN by jupydo-check.
# If the image is OLDER than the bundle, apt brings forward (only) the packages the
# bundle's -dev packages need, from the bundle: it also holds the official image's own
# packages of its day (e.g. util-linux, which requires its exact libuuid1). Every step
# forward is listed in /opt/jupydo/apt-upgrades.txt and shown as WARN too.
# APT::Default-Release is emptied: some images set it (e.g. "testing", in images based on
# rocker/r-base), and with only the bundle as source apt refuses an unknown release.
COPY selected/apt /tmp/vendor-apt
RUN export DEBIAN_FRONTEND=noninteractive \
 && V=/tmp/vendor-apt \
 && mkdir -p $V/state/partial $V/prefs.d /opt/jupydo \
 && echo "deb [trusted=yes] file:$V/debs ./" > $V/vendor.list \
 && APT_ONLY_VENDOR=(-o Dir::Etc::sourcelist=$V/vendor.list -o Dir::Etc::sourceparts=- \
                     -o Dir::State::Lists=$V/state -o APT::Get::List-Cleanup=0 \
                     -o APT::Default-Release=) \
 && installed() { dpkg-query -W -f '${db:Status-Abbrev} ${Package}:${Architecture} ${Version}\n' \
                  | awk '$1 == "ii" {print $2, $3}' | sort; } \
 && installed > $V/before.txt \
 && : > /opt/jupydo/apt-skipped.txt && : > /opt/jupydo/apt-online.txt \
 && apt-get "${APT_ONLY_VENDOR[@]}" update \
 && if ! apt-get "${APT_ONLY_VENDOR[@]}" install -y --no-install-recommends --allow-downgrades --no-remove \
          $(cat $V/lists/base.txt); then \
      echo "JupyDo: the image has other versions of some packages than the apt bundle:" \
           "retrying with the bundle's versions (step back, nothing removed)" >&2; \
      printf 'Package: *\nPin: origin ""\nPin-Priority: 1001\n' > $V/prefs.d/jupydo-vendor.pref; \
      cut -d: -f1 $V/before.txt | awk 'NR == FNR {have[$1]; next} !($1 in have)' - $V/lists/base.txt \
        > $V/missing.txt; \
      if ! apt-get "${APT_ONLY_VENDOR[@]}" -o Dir::Etc::preferencesparts=$V/prefs.d \
             install -y --no-install-recommends --allow-downgrades --no-remove $(cat $V/missing.txt) \
         && ! { echo "JupyDo: trying the distribution's archive too (the image's own apt sources," \
                     "online), for the versions the bundle does not have" >&2; \
                mkdir -p $V/online.d $V/online-state/partial; \
                cp -a /etc/apt/sources.list.d/. $V/online.d/ 2>/dev/null; \
                [ -f /etc/apt/sources.list ] && cp /etc/apt/sources.list $V/online.d/image.list; \
                cp $V/vendor.list $V/online.d/jupydo-bundle.list; \
                ONLINE=(-o Dir::Etc::sourcelist=/dev/null -o Dir::Etc::sourceparts=$V/online.d \
                        -o Dir::State::Lists=$V/online-state -o APT::Default-Release=); \
                installed > $V/before-online.txt; \
                apt-get "${ONLINE[@]}" update \
                && apt-get "${ONLINE[@]}" install -y --no-install-recommends --allow-downgrades --no-remove \
                     $(cat $V/missing.txt) \
                && { installed | comm -13 $V/before-online.txt - >> /opt/jupydo/apt-online.txt; \
                     echo "WARNING: packages taken from the distribution's archive (online):" >&2; \
                     sed 's/^/  /' /opt/jupydo/apt-online.txt >&2; }; }; then \
        echo "JupyDo: some packages of the bundle would remove packages of the image:" \
             "skipping them (the image's packages are kept)" >&2; \
        : > $V/ok.txt; \
        for p in $(cat $V/missing.txt); do \
          if apt-get "${APT_ONLY_VENDOR[@]}" -o Dir::Etc::preferencesparts=$V/prefs.d -s \
               install --no-install-recommends --allow-downgrades "$p" 2>/dev/null | grep -q '^Remv '; then \
            echo "$p" >> /opt/jupydo/apt-skipped.txt; else echo "$p" >> $V/ok.txt; fi; \
        done; \
        sed 's/^/  skipped (would remove packages of the image): /' /opt/jupydo/apt-skipped.txt >&2; \
        apt-get "${APT_ONLY_VENDOR[@]}" -o Dir::Etc::preferencesparts=$V/prefs.d \
          install -y --no-install-recommends --allow-downgrades --no-remove $(cat $V/ok.txt); \
      fi; \
    fi \
 && installed > $V/after.txt \
 && : > /opt/jupydo/apt-downgrades.txt && : > /opt/jupydo/apt-upgrades.txt \
 && join $V/before.txt $V/after.txt | while read -r pkg old new; do \
      if dpkg --compare-versions "$new" lt "$old"; then \
        echo "$pkg $old -> $new" >> /opt/jupydo/apt-downgrades.txt; \
      elif dpkg --compare-versions "$new" gt "$old"; then \
        echo "$pkg $old -> $new" >> /opt/jupydo/apt-upgrades.txt; fi; done \
 && if [ -s /opt/jupydo/apt-downgrades.txt ]; then \
      echo "WARNING: packages of the image stepped back to the bundle's version:" >&2; \
      sed 's/^/  /' /opt/jupydo/apt-downgrades.txt >&2; fi \
 && if [ -s /opt/jupydo/apt-upgrades.txt ]; then \
      echo "WARNING: packages of the image brought forward to the bundle's version (image older than the bundle):" >&2; \
      sed 's/^/  /' /opt/jupydo/apt-upgrades.txt >&2; fi \
 && find $V -mindepth 1 -maxdepth 1 ! -name debs -exec rm -rf {} + \
 && rm -rf /var/cache/apt/archives/*.deb \
 && sh /usr/local/lib/jupydo/fix-ld-order.sh

# ---- 2. Python + JupyterLab: ready-made tree (owned by root, so users cannot
# break the stack JupyDo depends on; they install with pip --user).
# ADD extracts the archive itself, outside the container: no tar of the image is
# needed (under QEMU emulation the tar of recent distributions fails).
ADD selected/python/python4jup.tar.gz /opt/
# An image that sets PYTHONHOME or PYTHONPATH (for its own Python, e.g. PYTHONHOME=/usr/local)
# would make JupyDo's Python load the image's standard library ("SRE module mismatch").
# There JupyDo's Python is started with -E (it ignores PYTHON* variables) by a small
# launcher in place of its binary: the variables stay in the environment, so the
# image's own Python, its kernels and the terminals still get them.
RUN if [ -n "${PYTHONHOME:-}${PYTHONPATH:-}" ]; then \
      real="$(readlink -f /opt/python4Jup/bin/python3)" \
   && mv "$real" "$real-jupydo" \
   && printf '#!/bin/sh\nexec "%s-jupydo" -E "$@"\n' "$real" > "$real" && chmod 755 "$real" \
   && /opt/python4Jup/bin/python3 -c 'import json, re' \
   && mkdir -p /opt/jupydo \
   && echo "JupyDo's Python ignores the image's PYTHONHOME/PYTHONPATH (started with -E)" >> /opt/jupydo/ld-paths.txt; \
    fi

# ---- 3. Kernels: every Python and R of the image becomes a Jupyter kernel, without
# changing it (modules/register-kernels.py). They were found by the builder in the
# ORIGINAL image (modules/detect-image.sh -> selected/kernels.txt). Pythons without
# ipykernel get the kernel libraries of their version (only those versions are in
# selected/kernel-libs.tar.gz); Rs without IRkernel get it compiled from the CRAN
# snapshot for their version, in a separate library. Every kernel is test-started.
# JupyDo's own Python (/opt/python4Jup) is NOT a kernel: it only runs JupyterLab.
ADD selected/kernel-libs.tar.gz /opt/jupydo/kernel-libs/
COPY selected/r /tmp/vendor-r
COPY selected/kernels.txt /tmp/jupydo-kernels.txt
COPY modules/register-kernels.py /tmp/register-kernels.py
RUN /opt/python4Jup/bin/python3 /tmp/register-kernels.py /tmp/jupydo-kernels.txt /tmp/vendor-r \
 && rm -rf /tmp/vendor-r /tmp/register-kernels.py /tmp/jupydo-kernels.txt

# ---- 4. Optional modules (JUPYDO_MODULES, e.g. "apptainer"): each one from its own
# self-contained bundle (program + the system packages it needs). The base apt bundle
# (kept in /tmp/vendor-apt/debs until here: its COPY layer exists anyway) is a second
# source for them: if a module needs newer versions of packages the image has (e.g.
# RStudio's libraries need a newer patch of the image's compilers), apt upgrades them
# from it instead of removing them; it is deleted at the end of this step. ADD extracts Apptainer outside the container (works under
# QEMU emulation too); with the module off the archive is empty.
ARG JUPYDO_MODULES=""
ADD selected/apptainer.tar.gz /opt/
COPY selected/modules /tmp/jupydo-modules
COPY modules /tmp/jupydo-module-scripts
# A module that cannot be added without removing packages of the image (its script
# exits with 100) is left out with a warning: modules-skipped.txt. A module whose
# installation fails for any other reason is left out too (the rest of the environment
# is built), but recorded apart as a failure: modules-failed.txt (jupydo-check, tests).
RUN : > /opt/jupydo/modules-skipped.txt && : > /opt/jupydo/modules-failed.txt \
 && for module in ${JUPYDO_MODULES}; do \
      bash "/tmp/jupydo-module-scripts/install-${module}.sh" "/tmp/jupydo-modules/${module}"; rc=$?; \
      if [ "$rc" = 100 ]; then \
        echo "WARNING: module ${module} left out: it cannot be added to this image without" \
             "removing packages of the image (the rest of the environment is built)" >&2; \
        echo "${module}" >> /opt/jupydo/modules-skipped.txt; \
      elif [ "$rc" != 0 ]; then \
        echo "WARNING: module ${module} left out: its installation failed (exit ${rc}, see above;" \
             "the rest of the environment is built)" >&2; \
        echo "${module}" >> /opt/jupydo/modules-failed.txt; \
      fi; \
    done \
 && rm -rf /tmp/jupydo-modules /tmp/jupydo-module-scripts /tmp/vendor-apt \
 && sh /usr/local/lib/jupydo/fix-ld-order.sh
ENV JUPYDO_MODULES="${JUPYDO_MODULES}"
LABEL org.jupydo.modules="${JUPYDO_MODULES}"

# ---- 5. Runtime: the default user, the entrypoint (per-user account + sudo) and
# the check of the whole stack (the build fails if something is missing; JupyDo
# also runs it to decide whether an image is ready)
RUN id jovyan >/dev/null 2>&1 || useradd -m -s /bin/bash jovyan
COPY modules/jupydo-entrypoint.sh /usr/local/bin/jupydo-entrypoint
COPY modules/jupydo-check.sh /usr/local/bin/jupydo-check
# jupydo-selftest: the environment self-test, as a terminal command for every image
# (also those without Python). It runs on JupyDo's Python, by its full path.
COPY modules/jupydo-selftest.py /usr/local/lib/jupydo/selftest.py
RUN printf '#!/bin/sh\nexec /opt/python4Jup/bin/python3 /usr/local/lib/jupydo/selftest.py "$@"\n' \
      > /usr/local/bin/jupydo-selftest \
 && chmod 755 /usr/local/bin/jupydo-selftest /usr/local/lib/jupydo/selftest.py
RUN chmod 755 /usr/local/bin/jupydo-entrypoint /usr/local/bin/jupydo-check \
 && /usr/local/bin/jupydo-check

# An image is "ready" for JupyDo only if this matches the current builder version
ARG JUPYDO_BUILDER_VERSION=dev
LABEL org.jupydo.builder="${JUPYDO_BUILDER_VERSION}"

ENV HOME=/home/jovyan
WORKDIR /home/jovyan
# The base image's healthcheck (if any) expects its own Jupyter setup, not ours
HEALTHCHECK NONE
# Starts as root: the entrypoint creates the user's account (NB_USER / NB_UID from
# JupyDo), gives it sudo and then runs the command as that user.
USER root
ENTRYPOINT ["/usr/local/bin/jupydo-entrypoint"]
CMD ["/opt/python4Jup/bin/jupyterhub-singleuser"]
