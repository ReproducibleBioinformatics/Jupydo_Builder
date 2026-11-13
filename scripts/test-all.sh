#!/usr/bin/env bash
# Tests the builder on:
#   - the official image of every distribution in lists/distros.txt, for each
#     architecture of ARCHS (default: amd64 arm64; arm64 needs QEMU, slow);
#   - the real images of lists/test-images.txt, on the architectures listed there,
#     also checking each is detected as the expected distribution.
# For each image:
#   build    scripts/build-image.sh (offline install + jupydo-check)
#   kernels  starts the Python kernel (and the R kernel if there is R), runs 6*7
#   user     the entrypoint creates a personal account (UID 10999) with sudo
#   compile  a C and a Fortran program, compiled and run offline
# Results: a table at the end, tests/results-<date>.tsv, logs in tests/logs/.
# RUN_DIR=<folder>: results and logs go there instead of tests/ (to keep a run apart).
# Test images are tagged jupydo-test/...: removed at the end unless KEEP=1.
#
# Usage (from the builder folder):
#   scripts/test-all.sh                  everything
#   scripts/test-all.sh official         only the official distro images
#   scripts/test-all.sh real             only lists/test-images.txt
#   scripts/test-all.sh apptainer        Apptainer module on every distro x ARCHS:
#                                        build with the module, then a real unprivileged
#                                        "apptainer exec docker://alpine" in a container
#                                        started as JupyDo does (FUSE + the two security
#                                        profiles; run scripts/setup-host.sh first), and
#                                        a container of the other architecture (sandbox
#                                        folder, its programs emulated by the kernel).
#                                        Emulated images: N/A (Apptainer's starter cannot
#                                        run under QEMU user-mode; JupyDo refuses them).
#   scripts/test-all.sh rstudio          RStudio module on the real images (lists/test-images.txt)
#                                        whose platform has an RStudio bundle: build with the
#                                        module, then RStudio Server is started as a normal
#                                        user (as JupyterLab starts it) and must answer.
#   scripts/test-all.sh vscode           VS Code module on the real images, code-server started
#                                        as JupyterLab starts it must answer
#   scripts/test-all.sh desktop          Desktop module on the real images: the desktop started as
#                                        JupyterLab starts it (VNC answers, XFCE session running)
#   scripts/test-all.sh igv              IGV module on the real images: the IGV server started as
#                                        JupyterLab starts it (app page, range request on a file)
#   LIST=<file> RUN_DIR=<folder> scripts/test-all.sh big
#                                        large-scale test (scripts/bigtest/make-lists.py): every
#                                        image of the list (BIG_ARCH: this machine's architecture
#                                        by default; LIMIT=n: only the first n), built classic and with all the
#                                        modules of its platform; ONE row per image in
#                                        <folder>/big-results.tsv; only what the test created is
#                                        removed afterwards; a restart goes on where it stopped;
#                                        network errors are tried again until the image has a real result (pauses 1-15 min, waiting for the network to come back; NET_TRIES=n stops after n tries: NETWORK); an image no longer on its registry (deleted by its authors) is UNAVAILABLE, not a failure
#   scripts/test-all.sh combos           EVERY combination of 2+ modules on one image per platform
#                                        (lists/test-combos.txt), amd64
#   scripts/test-all.sh modules          ALL the modules available for each real image's platform
#                                        together (today apptainer + rstudio), each one checked:
#                                        modules must work alone (above) and all together (here)
#   ARCHS=amd64 scripts/test-all.sh      official images only for amd64
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"
ARCHS="${ARCHS:-amd64 arm64}"
WHAT="${1:-all}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${RUN_DIR:-tests}"
mkdir -p "$OUT/logs"
RESULTS="$OUT/results-${STAMP}.tsv"
printf 'image\tarch\tplatform\tbuild\tkernels\tpy_kernels\tr_kernels\tuser\tcompile\tminutes\n' > "$RESULTS"
HOST_ARCH="$(docker info --format '{{.Architecture}}' 2>/dev/null | sed 's/x86_64/amd64/; s/aarch64/arm64/')"

read_list() { sed 's/#.*//' "$1" | awk 'NF {print $1}'; }

# QEMU registered with the "C" (credentials) flag runs setuid programs (sudo) too
emulator_has_credentials() {  # $1 = architecture of the image
  local name=qemu-x86_64; [ "$1" = arm64 ] && name=qemu-aarch64
  grep -q '^flags: .*C' "/proc/sys/fs/binfmt_misc/${name}" 2>/dev/null
}

run_test() {  # $1 = base image, $2 = architecture, $3 = expected platform ("-" any, "unsupported")
  local base="$1" arch="$2" expected="${3:--}" start build=- kernels=- user=- compile=- platform=- npy=- nr=-
  local slug; slug="$(echo "${base%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')"
  local tag="jupydo-test/${slug}:${arch}" log="$OUT/logs/${STAMP}-${slug}-${arch}.log"
  local plat=(--platform "linux/${arch}")
  start=$(date +%s)
  echo
  echo "=== ${base} (${arch}) ==="
  local built=0
  PLATFORM="linux/${arch}" scripts/build-image.sh "$base" "$tag" > "$log" 2>&1 && built=1
  # which distribution it was detected as, compared with the expected one
  local detected; detected="$(sed -n 's/^Base image: .* -> \([^ ]*\) .*/\1/p' "$log" | head -1)"
  detected="${detected%-${arch}}"
  if [ "$expected" = unsupported ]; then
    if [ "$built" = 0 ] && grep -qiE "not supported|missing bundle|cannot read|no Python bundle" "$log"; then
      platform=unsupported; build=REFUSED
    else
      platform="FAIL(${detected:-?})"; build="FAIL(not refused)"
    fi
  elif [ "$expected" = "-" ] || [ "$detected" = "$expected" ]; then
    platform="${detected:-?}"
  else
    platform="MISMATCH(${detected:-?})"
  fi
  if [ "$expected" = unsupported ]; then
    :
  elif [ "$built" = 1 ]; then
    build=PASS
    # kernels: real kernels started by the JupyterLab Python, a computation executed
    if docker run --rm "${plat[@]}" --entrypoint /opt/python4Jup/bin/python3 \
         -v "${ROOT}/scripts/lib/test-kernels.py:/test-kernels.py:ro" "$tag" /test-kernels.py >> "$log" 2>&1; then
      kernels=PASS; else kernels=FAIL; fi
    npy="$(grep -o 'KERNELS python=[0-9]*' "$log" | tail -1 | cut -d= -f2)"; npy="${npy:--}"
    nr="$(grep -o 'KERNELS python=[0-9]* r=[0-9]*' "$log" | tail -1 | sed 's/.* r=//')"; nr="${nr:--}"
    # a Python or R of the image that should have become a kernel and did not (e.g.
    # IRkernel did not compile) is a failure, even if the other kernels work; only
    # the deliberate skip of a too-old Python (< 3.8) is not
    if [ "$kernels" = PASS ] && grep -e '-> NO kernel:' "$log" | grep -qv 'is too old'; then
      kernels=FAIL; fi
    # user: what JupyDo does at every start (personal account, UID, sudo).
    # Under QEMU emulation without the "C" flag setuid programs like sudo cannot
    # run: sudo is then checked statically (setuid bit + the user's rule), PASS*.
    if [ "$arch" = "${HOST_ARCH:-amd64}" ] || emulator_has_credentials "$arch"; then
      mode=real; pass=PASS; else mode=static; pass='PASS*'; fi
    if docker run --rm "${plat[@]}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 --entrypoint bash \
         -v "${ROOT}/scripts/lib/test-user.sh:/test-user.sh:ro" "$tag" /test-user.sh "$mode" 2>>"$log" \
         | tee -a "$log" | grep -q USER_OK; then
      user="$pass"; else user=FAIL; fi
    # compile: the base toolchain works offline (C and Fortran)
    if docker run --rm "${plat[@]}" --network none --entrypoint sh \
         -v "${ROOT}/scripts/lib/test-compile.sh:/test-compile.sh:ro" "$tag" /test-compile.sh >> "$log" 2>&1; then
      compile=PASS; else compile=FAIL; fi
    [ "${KEEP:-0}" = "1" ] || docker rmi "$tag" > /dev/null 2>&1
  else
    build=FAIL
  fi
  local minutes=$(( ($(date +%s) - start + 59) / 60 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${base%@*}" "$arch" "$platform" "$build" "$kernels" "$npy" "$nr" "$user" "$compile" "$minutes" >> "$RESULTS"
  echo "platform ${platform} | build ${build} | kernels ${kernels} (python ${npy}, R ${nr}) | user ${user} | compile ${compile} | ${minutes} min | log: ${log}"
}

run_apptainer_test() {  # $1 = base image, $2 = architecture
  local base="$1" arch="$2" start build=- check=- exec=- other=-
  local slug; slug="$(echo "${base%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')"
  local tag="jupydo-test/${slug}:${arch}-apptainer" log="$OUT/logs/${STAMP}-${slug}-${arch}-apptainer.log"
  local plat=(--platform "linux/${arch}")
  # as JupyDo starts containers with the module
  local secure=(--device /dev/fuse --security-opt "seccomp=${ROOT}/security/apptainer-seccomp.json")
  [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ] && secure+=(--security-opt apparmor=jupydo-apptainer)
  start=$(date +%s)
  echo
  echo "=== ${base} (${arch}) + apptainer ==="
  if MODULES=apptainer PLATFORM="linux/${arch}" scripts/build-image.sh "$base" "$tag" > "$log" 2>&1; then
    build=PASS
    if grep -q "OK   module apptainer" "$log"; then check=PASS; else check=FAIL; fi
    if [ "$arch" != "${HOST_ARCH:-amd64}" ]; then
      exec=N/A; other=N/A   # emulated: Apptainer cannot run under QEMU user-mode
    else
      if docker run --rm "${plat[@]}" "${secure[@]}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 "$tag" \
           bash -c 'cd /tmp && apptainer exec docker://alpine:3.20 cat /etc/alpine-release' >> "$log" 2>&1; then
        exec=PASS; else exec=FAIL; fi
      # a container of the other architecture (its programs emulated by the kernel)
      local other_arch=arm64 expect=aarch64
      [ "$arch" = arm64 ] && { other_arch=amd64; expect=x86_64; }
      if docker run --rm "${plat[@]}" "${secure[@]}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 "$tag" \
           bash -c "cd /tmp && apptainer build --arch ${other_arch} --fix-perms --sandbox /tmp/other docker://alpine:3.20 >&2 && apptainer exec /tmp/other uname -m" 2>>"$log" \
           | tee -a "$log" | grep -qx "$expect"; then
        other=PASS; else other=FAIL; fi
    fi
    [ "${KEEP:-0}" = "1" ] || docker rmi "$tag" > /dev/null 2>&1
  elif grep -q "module apptainer is not available for" "$log"; then
    build=REFUSED   # no Apptainer on this platform by design (e.g. Ubuntu 16.04/18.04)
  else
    build=FAIL
  fi
  local minutes=$(( ($(date +%s) - start + 59) / 60 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${base%@*}" "$arch" "$build" "$check" "$exec" "$other" "$minutes" >> "$RESULTS"
  echo "build ${build} | check ${check} | apptainer exec ${exec} | other arch ${other} | ${minutes} min | log: ${log}"
}

run_rstudio_test() {  # $1 = base image, $2 = architecture
  local base="$1" arch="$2" start build=- check=- http=-
  local slug; slug="$(echo "${base%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')"
  local tag="jupydo-test/${slug}:${arch}-rstudio" log="$OUT/logs/${STAMP}-${slug}-${arch}-rstudio.log"
  start=$(date +%s)
  echo
  echo "=== ${base} (${arch}) + rstudio ==="
  if MODULES=rstudio PLATFORM="linux/${arch}" scripts/build-image.sh "$base" "$tag" > "$log" 2>&1; then
    build=PASS
    if grep -q "OK   module rstudio" "$log"; then check=PASS; else check=FAIL; fi
    # RStudio Server started as a normal user exactly as JupyterLab starts it
    # (command and environment taken from jupyter-rsession-proxy itself); with no R
    # in the image it cannot start until the user installs one: N/A
    if ! grep -q "found: R " "$log"; then http=N/A
    elif docker run --rm --platform "linux/${arch}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 \
         -v "$(pwd)/scripts/lib/rstudio-smoke.py:/tmp/rstudio-smoke.py:ro" \
         "$tag" /opt/python4Jup/bin/python3 /tmp/rstudio-smoke.py >> "$log" 2>&1; then
      http=PASS; else http=FAIL; fi
    [ "${KEEP:-0}" = "1" ] || docker rmi "$tag" > /dev/null 2>&1
  elif grep -q "module rstudio is not available for" "$log"; then
    build=REFUSED   # no RStudio bundle for this platform (e.g. Ubuntu 16.04/18.04)
  else
    build=FAIL
  fi
  local minutes=$(( ($(date +%s) - start + 59) / 60 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${base%@*}" "$arch" "$build" "$check" "$http" "$minutes" >> "$RESULTS"
  echo "build ${build} | check ${check} | rstudio answers ${http} | ${minutes} min | log: ${log}"
}

run_modules_test() {  # $1 = base image, $2 = architecture, [$3 = modules, default: all available]
  local base="$1" arch="$2" start build=- check=- exec=- rs=- vs=- ds=- ig=- mods=""
  local slug; slug="$(echo "${base%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')"
  local combo; combo="$(echo "${3:-all}" | tr ' ' '_')"   # no "+": not allowed in a Docker tag
  local tag="jupydo-test/${slug}:${arch}-${combo}" log="$OUT/logs/${STAMP}-${slug}-${arch}-${combo}.log"
  local plat=(--platform "linux/${arch}")
  local secure=(--device /dev/fuse --security-opt "seccomp=${ROOT}/security/apptainer-seccomp.json")
  [ "$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null)" = Y ] && secure+=(--security-opt apparmor=jupydo-apptainer)
  start=$(date +%s)
  echo
  echo "=== ${base} (${arch}) + all modules ==="
  # the platform as the builder sees it (BusyBox images: after the conversion)
  local key; key="$(docker run --rm "${plat[@]}" --entrypoint /bin/sh "$base" -c "$(cat modules/detect-image.sh)" 2>/dev/null \
    | awk '$1 == "OS" {print $2 "-" $3 "-" $4} $1 == "CONDA_ONLY" {c = $3} END {if (c) print "debian-12-" c}' | tail -1)"
  for m in ${3:-$(ls modules/install-*.sh | sed 's#modules/install-##; s#\.sh$##')}; do
    [ -f "vendor/${m}/${key}/.complete" ] && mods="${mods:+$mods }$m"
  done
  if [ -z "$mods" ]; then
    build=REFUSED   # no module for this platform (e.g. Ubuntu 16.04/18.04)
  elif MODULES="$mods" PLATFORM="linux/${arch}" scripts/build-image.sh "$base" "$tag" > "$log" 2>&1; then
    build=PASS; check=PASS
    for m in $mods; do grep -q "OK   module ${m}" "$log" || check=FAIL; done
    case " $mods " in *" apptainer "*)
      if [ "$arch" != "${HOST_ARCH:-amd64}" ]; then exec=N/A
      elif docker run --rm "${plat[@]}" "${secure[@]}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 "$tag" \
             bash -c 'cd /tmp && apptainer exec docker://alpine:3.20 cat /etc/alpine-release' >> "$log" 2>&1; then exec=PASS
      else exec=FAIL; fi ;;
    esac
    case " $mods " in *" rstudio "*)
      if ! grep -q "found: R " "$log"; then rs=N/A
      elif docker run --rm "${plat[@]}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 \
           -v "$(pwd)/scripts/lib/rstudio-smoke.py:/tmp/rstudio-smoke.py:ro" \
           "$tag" /opt/python4Jup/bin/python3 /tmp/rstudio-smoke.py >> "$log" 2>&1; then rs=PASS; else rs=FAIL; fi ;;
    esac
    case " $mods " in *" igv "*)
      if docker run --rm "${plat[@]}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 \
           -v "$(pwd)/scripts/lib/igv-smoke.py:/tmp/igv-smoke.py:ro" \
           "$tag" /opt/python4Jup/bin/python3 /tmp/igv-smoke.py >> "$log" 2>&1; then ig=PASS; else ig=FAIL; fi ;;
    esac
    case " $mods " in *" desktop "*)
      if docker run --rm "${plat[@]}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 \
           -v "$(pwd)/scripts/lib/desktop-smoke.py:/tmp/desktop-smoke.py:ro" \
           "$tag" /opt/python4Jup/bin/python3 /tmp/desktop-smoke.py >> "$log" 2>&1; then ds=PASS; else ds=FAIL; fi ;;
    esac
    case " $mods " in *" vscode "*)
      if docker run --rm "${plat[@]}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 \
           -v "$(pwd)/scripts/lib/vscode-smoke.py:/tmp/vscode-smoke.py:ro" \
           "$tag" /opt/python4Jup/bin/python3 /tmp/vscode-smoke.py >> "$log" 2>&1; then vs=PASS; else vs=FAIL; fi ;;
    esac
    [ "${KEEP:-0}" = "1" ] || docker rmi "$tag" > /dev/null 2>&1
  else
    build=FAIL
  fi
  local minutes=$(( ($(date +%s) - start + 59) / 60 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${base%@*}" "$arch" "${mods// /+}" "$build" "$check" "$exec" "$rs" "$vs" "$ds" "$ig" "$minutes" >> "$RESULTS"
  echo "modules ${mods:-none} | build ${build} | check ${check} | apptainer exec ${exec} | rstudio answers ${rs} | vscode answers ${vs} | desktop works ${ds} | igv works ${ig} | ${minutes} min | log: ${log}"
}


if [ "$WHAT" = "big" ]; then
  LIST="${LIST:?give the list: LIST=lists/bigtest/bigtest-<date>-<arch>.tsv}"
  # the architecture the images are built for: this machine's by default; the other
  # one runs in emulation (QEMU)
  host_arch="${HOST_ARCH:-amd64}"
  BIG_ARCH="${BIG_ARCH:-$host_arch}"
  LIMIT="${LIMIT:-0}"   # >0: only the first LIMIT images of the list (they are in order of use)
  BIG="$OUT/big-results.tsv"
  [ -f "$BIG" ] || printf 'set\timage\tplatform\tclassic\tkernels\tpy_kernels\tr_kernels\tuser\tcompile\tmodules\tmodules_build\tmodules_check\tapptainer\trstudio\tvscode\tdesktop\tigv\tminutes\treason\n' > "$BIG"
  NETRE='failed to resolve reference|i/o timeout|x509:|TLS handshake|no such host|connection refused|connection reset|connection timed out|toomanyrequests|unexpected EOF|net/http|failed to copy: read tcp'
  NET_TRIES="${NET_TRIES:-0}"   # tries of an image that fails for the network: 0 = until a real result
  # the image (or its digest) is no longer on its registry: deleted, not a network error
  UNRE='manifest unknown|repository does not exist|pull access denied|requested access to the resource is denied|name unknown'

  # Waits until the registries answer (any HTTP answer: 401 without login is fine),
  # e.g. after the university network cut; checks every minute.
  wait_for_network() {
    local said=0
    until [ "$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' https://registry-1.docker.io/v2/)" != 000 ] \
          && [ "$(curl -s -o /dev/null --max-time 15 -w '%{http_code}' https://quay.io/v2/)" != 000 ]; do
      [ "$said" = 1 ] || { echo "  network down: waiting for Docker Hub and quay.io to answer ($(date +%H:%M))"; said=1; }
      sleep 60
    done
    [ "$said" = 0 ] || echo "  network back ($(date +%H:%M))"
  }
  total=$(grep -vc '^#' "$LIST"); n=0
  [ "$LIMIT" -gt 0 ] && [ "$LIMIT" -lt "$total" ] && total=$LIMIT
  echo "big: $total images for $BIG_ARCH on a $host_arch machine$([ "$BIG_ARCH" != "$host_arch" ] && echo ' (emulated)')"
  while IFS=$'\t' read -r set image _; do
    case "$set" in ''|'#'*) continue ;; esac
    n=$((n + 1))
    [ "$LIMIT" -gt 0 ] && [ "$n" -gt "$LIMIT" ] && break
    # done already (anything but a network failure): skip
    if awk -F'\t' -v i="$image" '$2 == i && $4 != "NETWORK" {f = 1} END {exit !f}' "$BIG"; then continue; fi
    # a previous network failure of this image is tried again: its row goes
    awk -F'\t' -v i="$image" '!($2 == i && $4 == "NETWORK")' "$BIG" > "$BIG.tmp" && mv "$BIG.tmp" "$BIG"
    echo; echo "##### [$n/$total] $set $image"
    big_start=$(date +%s)
    had_base=0; docker image inspect "$image" >/dev/null 2>&1 && had_base=1
    slug="$(echo "${image%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')"
    attempt=0
    while :; do
    attempt=$((attempt + 1))
    if [ "$attempt" -gt 1 ]; then
      pause=$(( attempt == 2 ? 1 : attempt == 3 ? 2 : attempt == 4 ? 4 : attempt == 5 ? 8 : 15 ))
      echo "  network error: attempt $attempt$([ "$NET_TRIES" -gt 0 ] && echo " of $NET_TRIES") in $pause min"
      sleep $(( pause * 60 )); wait_for_network
    fi
    # 1. classic
    RESULTS="$OUT/.big-classic.tsv"; : > "$RESULTS"
    run_test "$image" "$BIG_ARCH" -
    IFS=$'\t' read -r _ _ platform classic kernels npy nr user compile _ < "$RESULTS"
    clog="$OUT/logs/${STAMP}-${slug}-${BIG_ARCH}.log"
    reason=""
    if [ "$classic" != PASS ]; then
      if grep -qE "$UNRE" "$clog"; then classic=UNAVAILABLE
      elif grep -qE "$NETRE" "$clog"; then classic=NETWORK
      elif grep -qiE "not supported|no linux/[a-z0-9]+ version|has no linux/[a-z0-9]+|missing bundle: vendor/apt/|no Python bundle for glibc" "$clog"; then classic=REFUSED; fi
      if [ "$classic" = UNAVAILABLE ]; then
        reason="$(grep -m1 -E "$UNRE" "$clog" | sed 's/\t/ /g' | cut -c1-200)"
      elif [ "$classic" = NETWORK ]; then   # the network message itself (e.g. of the image download)
        reason="$(grep -m1 -E "$NETRE" "$clog" | sed 's/\t/ /g' | cut -c1-200)"
      else
        reason="$(grep -m1 -E "^ERROR|ERROR:|error:" "$clog" | sed 's/\t/ /g' | cut -c1-200)"
      fi
    elif [ "$kernels" != PASS ]; then
      reason="$(grep -m1 -E -- "-> NO kernel:|ERROR" "$clog" | sed 's/\t/ /g' | cut -c1-200)"
    fi
    # 2. all the modules of its platform (only if the classic build passed)
    mods=-; mb=-; mc=-; ap=-; rs=-; vs=-; ds=-; ig=-
    if [ "$classic" = PASS ]; then
      RESULTS="$OUT/.big-modules.tsv"; : > "$RESULTS"
      run_modules_test "$image" "$BIG_ARCH"
      IFS=$'\t' read -r _ _ mods mb mc ap rs vs ds ig _ < "$RESULTS"
      mlog="$OUT/logs/${STAMP}-${slug}-${BIG_ARCH}-all.log"
      if [ "$mb" != PASS ] && [ "$mb" != REFUSED ]; then
        grep -qE "$NETRE" "$mlog" && mb=NETWORK
        [ -n "$reason" ] || reason="modules: $(grep -m1 -E "^ERROR|ERROR:|error:" "$mlog" | sed 's/\t/ /g' | cut -c1-190)"
      fi
    fi
    # a network failure (classic or modules) is tried again; anything else is the result
    [ "$classic" = NETWORK ] || [ "$mb" = NETWORK ] || break
    [ "$NET_TRIES" -gt 0 ] && [ "$attempt" -ge "$NET_TRIES" ] && break
    done
    # 3. clean what this test created: the converted image, the base image if it
    # was not here before, and the build cache above 50 GB
    docker rmi "jupydo-converted/${slug}:${BIG_ARCH}" >/dev/null 2>&1 || true
    [ "$had_base" = 1 ] || docker rmi "$image" >/dev/null 2>&1 || true
    docker builder prune -f --keep-storage "${KEEP_CACHE:-50GB}" >/dev/null 2>&1 || true
    big_min=$(( ($(date +%s) - big_start + 59) / 60 ))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$set" "$image" "$platform" "$classic" "$kernels" "$npy" "$nr" "$user" "$compile" \
      "$mods" "$mb" "$mc" "$ap" "$rs" "$vs" "$ds" "$ig" "$big_min" "$reason" >> "$BIG"
  done < "$LIST"
  rm -f "$OUT/.big-classic.tsv" "$OUT/.big-modules.tsv"
  echo
  echo "=== big: $(grep -vc '^set' "$BIG") images in $BIG ==="
  awk -F'\t' 'NR > 1 {c[$1 " " $4]++} END {for (k in c) print "  " k ": " c[k]}' "$BIG" | sort
  exit 0
fi

if [ "$WHAT" = "combos" ]; then
  # every combination of 2 or more of the modules available for the image's platform
  printf 'image\tarch\tmodules\tbuild\tcheck\tapptainer_exec\trstudio_answers\tvscode_answers\tdesktop_works\tigv_works\tminutes\n' > "$RESULTS"
  ALL_MODS=($(ls modules/install-*.sh | sed 's#modules/install-##; s#\.sh$##'))
  while read -r image; do
    key="$(docker run --rm --platform linux/amd64 --entrypoint /bin/sh "$image" -c "$(cat modules/detect-image.sh)" 2>/dev/null \
      | awk '$1 == "OS" {print $2 "-" $3 "-" $4}')"
    avail=(); for m in "${ALL_MODS[@]}"; do [ -f "vendor/${m}/${key}/.complete" ] && avail+=("$m"); done
    n=${#avail[@]}
    for ((mask = 1; mask < (1 << n); mask++)); do
      set=(); for ((i = 0; i < n; i++)); do (( mask & (1 << i) )) && set+=("${avail[$i]}"); done
      [ "${#set[@]}" -ge 2 ] && run_modules_test "$image" amd64 "${set[*]}"
    done
  done < <(sed 's/#.*//' lists/test-combos.txt | awk 'NF')
fi

if [ "$WHAT" = "modules" ]; then
  printf 'image\tarch\tmodules\tbuild\tcheck\tapptainer_exec\trstudio_answers\tvscode_answers\tdesktop_works\tigv_works\tminutes\n' > "$RESULTS"
  while read -r image archs expected _; do
    [ "$expected" = unsupported ] && continue
    for arch in ${archs//,/ }; do
      case " $ARCHS " in *" $arch "*) run_modules_test "$image" "$arch" ;; esac
    done
  done < <(sed 's/#.*//' lists/test-images.txt | awk 'NF >= 3')
fi

run_vscode_test() {  # $1 = base image, $2 = architecture
  local base="$1" arch="$2" start build=- check=- http=-
  local slug; slug="$(echo "${base%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')"
  local tag="jupydo-test/${slug}:${arch}-vscode" log="$OUT/logs/${STAMP}-${slug}-${arch}-vscode.log"
  start=$(date +%s)
  echo
  echo "=== ${base} (${arch}) + vscode ==="
  if MODULES=vscode PLATFORM="linux/${arch}" scripts/build-image.sh "$base" "$tag" > "$log" 2>&1; then
    build=PASS
    if grep -q "OK   module vscode" "$log"; then check=PASS; else check=FAIL; fi
    # code-server started as a normal user exactly as JupyterLab starts it
    if docker run --rm --platform "linux/${arch}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 \
         -v "$(pwd)/scripts/lib/vscode-smoke.py:/tmp/vscode-smoke.py:ro" \
         "$tag" /opt/python4Jup/bin/python3 /tmp/vscode-smoke.py >> "$log" 2>&1; then
      http=PASS; else http=FAIL; fi
    [ "${KEEP:-0}" = "1" ] || docker rmi "$tag" > /dev/null 2>&1
  elif grep -q "module vscode is not available for" "$log"; then
    build=REFUSED   # no VS Code bundle for this platform (Ubuntu 16.04/18.04: glibc too old)
  else
    build=FAIL
  fi
  local minutes=$(( ($(date +%s) - start + 59) / 60 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${base%@*}" "$arch" "$build" "$check" "$http" "$minutes" >> "$RESULTS"
  echo "build ${build} | check ${check} | vscode answers ${http} | ${minutes} min | log: ${log}"
}

if [ "$WHAT" = "vscode" ]; then
  printf 'image\tarch\tbuild\tcheck\tvscode_answers\tminutes\n' > "$RESULTS"
  while read -r image archs expected _; do
    [ "$expected" = unsupported ] && continue
    for arch in ${archs//,/ }; do
      case " $ARCHS " in *" $arch "*) run_vscode_test "$image" "$arch" ;; esac
    done
  done < <(sed 's/#.*//' lists/test-images.txt | awk 'NF >= 3')
fi

run_desktop_test() {  # $1 = base image, $2 = architecture
  local base="$1" arch="$2" start build=- check=- http=-
  local slug; slug="$(echo "${base%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')"
  local tag="jupydo-test/${slug}:${arch}-desktop" log="$OUT/logs/${STAMP}-${slug}-${arch}-desktop.log"
  start=$(date +%s)
  echo
  echo "=== ${base} (${arch}) + desktop ==="
  if MODULES=desktop PLATFORM="linux/${arch}" scripts/build-image.sh "$base" "$tag" > "$log" 2>&1; then
    build=PASS
    if grep -q "OK   module desktop" "$log"; then check=PASS; else check=FAIL; fi
    # the desktop started as a normal user exactly as JupyterLab starts it
    if docker run --rm --platform "linux/${arch}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 \
         -v "$(pwd)/scripts/lib/desktop-smoke.py:/tmp/desktop-smoke.py:ro" \
         "$tag" /opt/python4Jup/bin/python3 /tmp/desktop-smoke.py >> "$log" 2>&1; then
      http=PASS; else http=FAIL; fi
    [ "${KEEP:-0}" = "1" ] || docker rmi "$tag" > /dev/null 2>&1
  elif grep -q "module desktop is not available for" "$log"; then
    build=REFUSED   # no Desktop bundle for this platform (Ubuntu 16.04-20.04: TigerVNC too old)
  else
    build=FAIL
  fi
  local minutes=$(( ($(date +%s) - start + 59) / 60 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${base%@*}" "$arch" "$build" "$check" "$http" "$minutes" >> "$RESULTS"
  echo "build ${build} | check ${check} | desktop works ${http} | ${minutes} min | log: ${log}"
}

if [ "$WHAT" = "desktop" ]; then
  printf 'image\tarch\tbuild\tcheck\tdesktop_works\tminutes\n' > "$RESULTS"
  while read -r image archs expected _; do
    [ "$expected" = unsupported ] && continue
    for arch in ${archs//,/ }; do
      case " $ARCHS " in *" $arch "*) run_desktop_test "$image" "$arch" ;; esac
    done
  done < <(sed 's/#.*//' lists/test-images.txt | awk 'NF >= 3')
fi

run_igv_test() {  # $1 = base image, $2 = architecture
  local base="$1" arch="$2" start build=- check=- http=-
  local slug; slug="$(echo "${base%@*}" | tr '[:upper:]' '[:lower:]' | sed 's#[^a-z0-9_.-]#-#g')"
  local tag="jupydo-test/${slug}:${arch}-igv" log="$OUT/logs/${STAMP}-${slug}-${arch}-igv.log"
  start=$(date +%s)
  echo
  echo "=== ${base} (${arch}) + igv ==="
  if MODULES=igv PLATFORM="linux/${arch}" scripts/build-image.sh "$base" "$tag" > "$log" 2>&1; then
    build=PASS
    if grep -q "OK   module igv" "$log"; then check=PASS; else check=FAIL; fi
    # the IGV server started as a normal user exactly as JupyterLab starts it
    if docker run --rm --platform "linux/${arch}" -e NB_USER=jdtest -e NB_UID=10999 -e NB_GID=100 \
         -v "$(pwd)/scripts/lib/igv-smoke.py:/tmp/igv-smoke.py:ro" \
         "$tag" /opt/python4Jup/bin/python3 /tmp/igv-smoke.py >> "$log" 2>&1; then
      http=PASS; else http=FAIL; fi
    [ "${KEEP:-0}" = "1" ] || docker rmi "$tag" > /dev/null 2>&1
  elif grep -q "module igv is not available for" "$log"; then
    build=REFUSED   # no IGV bundle for this platform (Ubuntu 16.04/18.04)
  else
    build=FAIL
  fi
  local minutes=$(( ($(date +%s) - start + 59) / 60 ))
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${base%@*}" "$arch" "$build" "$check" "$http" "$minutes" >> "$RESULTS"
  echo "build ${build} | check ${check} | igv works ${http} | ${minutes} min | log: ${log}"
}

if [ "$WHAT" = "igv" ]; then
  printf 'image\tarch\tbuild\tcheck\tigv_works\tminutes\n' > "$RESULTS"
  while read -r image archs expected _; do
    [ "$expected" = unsupported ] && continue
    for arch in ${archs//,/ }; do
      case " $ARCHS " in *" $arch "*) run_igv_test "$image" "$arch" ;; esac
    done
  done < <(sed 's/#.*//' lists/test-images.txt | awk 'NF >= 3')
fi

RSTUDIO_NA_NOTE="N/A for RStudio = the image has no R: RStudio is installed and starts once the user installs R (e.g. sudo apt install r-base)."

if [ "$WHAT" = "rstudio" ]; then
  printf 'image\tarch\tbuild\tcheck\trstudio_answers\tminutes\n' > "$RESULTS"
  while read -r image archs expected _; do
    [ "$expected" = unsupported ] && continue
    for arch in ${archs//,/ }; do
      case " $ARCHS " in *" $arch "*) run_rstudio_test "$image" "$arch" ;; esac
    done
  done < <(sed 's/#.*//' lists/test-images.txt | awk 'NF >= 3')
fi

if [ "$WHAT" = "apptainer" ]; then
  printf 'image\tarch\tbuild\tcheck\tapptainer_exec\tother_arch_exec\tminutes\n' > "$RESULTS"
  for image in $(read_list lists/distros.txt); do
    for arch in $ARCHS; do run_apptainer_test "$image" "$arch"; done
  done
fi

if [ "$WHAT" = "all" ] || [ "$WHAT" = "official" ]; then
  for image in $(read_list lists/distros.txt); do
    for arch in $ARCHS; do run_test "$image" "$arch" "$(echo "$image" | tr ':' '-')"; done
  done
fi
if [ "$WHAT" = "all" ] || [ "$WHAT" = "real" ]; then
  while read -r image archs expected _; do
    for arch in ${archs//,/ }; do run_test "$image" "$arch" "$expected"; done
  done < <(sed 's/#.*//' lists/test-images.txt | awk 'NF >= 3')
fi

echo
echo "=== results (${RESULTS}) ==="
column -t -s $'\t' "$RESULTS"
case "$WHAT" in apptainer|modules|combos)
  awk -F'\t' 'NR > 1 && ($5 == "N/A" || $6 == "N/A")' "$RESULTS" | grep -q . \
    && echo "N/A for Apptainer = emulated architecture: Apptainer cannot run under QEMU user-mode emulation (JupyDo refuses it); it runs other-architecture containers from a native environment (other_arch_exec)." ;;
esac
case "$WHAT" in rstudio|modules|combos)
  awk -F'\t' -v c="$([ "$WHAT" = rstudio ] && echo 5 || echo 7)" 'NR > 1 && $c == "N/A"' "$RESULTS" | grep -q . \
    && echo "$RSTUDIO_NA_NOTE" ;;
esac
grep -q 'PASS\*' "$RESULTS" && echo "PASS* = emulated architecture, QEMU without the \"C\" flag: sudo checked statically (setuid bit + rule). JupyDo's first_start.sh adds the flag."
FAILED=$(awk -F'\t' 'NR > 1 && /FAIL|MISMATCH/' "$RESULTS" | wc -l)
echo
if [ "$FAILED" -eq 0 ]; then echo "All tests passed."; else echo "${FAILED} image(s) with failures: see their logs in $OUT/logs/."; fi
exit $(( FAILED > 0 ))
