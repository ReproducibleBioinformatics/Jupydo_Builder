# QEMU emulation: known problems and how the builder handles them

Images and bundles of the other architecture (arm64 on an amd64 machine, or vice
versa) run under QEMU user-mode emulation. It works, but it is slower and has a few
pitfalls. These are the ones found while building and testing the vendor bundles,
and what the builder does about each.

## 1. Setup: QEMU must be installed as a package

An emulation enabled by hand (`docker run --privileged tonistiigi/binfmt --install
arm64`) lives only in memory: it disappears at the next reboot. Install the
`qemu-user-static` package (`scripts/setup-host.sh` does it), which registers QEMU
again at every boot.

## 2. sudo inside emulated containers: the "C" flag

By default QEMU is registered without the "C" (credentials) flag
(`grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64` shows e.g. `POF`). Without it,
setuid programs such as `sudo` fail with "effective uid is not 0".
`scripts/setup-host.sh` installs a systemd service (`jupydo-qemu-credentials`) that
re-registers QEMU with the "C" flag at every boot (flags become e.g. `POFC`).
`test-all.sh` runs sudo for real when the flag is there, and marks the result
`PASS*` (sudo checked statically: setuid bit + the user's rule) when it is not.

## 3. Go programs can hang under emulation

Go programs may hang (0% CPU) or crawl under QEMU, because of Go's signal-based
asynchronous preemption. Seen with:

- `gosu` (switch from root to the user): the entrypoint now uses `setpriv`
  (util-linux, written in C, present in every Ubuntu/Debian image); `gosu` is only
  a fallback for images without `setpriv`;
- compiling Apptainer (Go) for arm64: the build hung after two hours. The Apptainer
  bundle build sets `GODEBUG=asyncpreemptoff=1`, which turns that mechanism off;
  with it an arm64 build takes about 30 minutes.

## 4. Old QEMU versions lack recent system calls

The `tar` of Ubuntu 26.04 uses system calls that older QEMU versions do not
implement: under the QEMU of Ubuntu/Pop!_OS 24.04 it fails with
"Cannot open: Function not implemented" / "Cannot mkdir: Function not implemented".

- The Dockerfile extracts archives with `ADD` (done by Docker itself, outside the
  container) instead of running `tar` in the image: it works for every image.
- The Apptainer bundles of the most recent distributions on arm64
  (`ubuntu-26.04-arm64`, `debian-13-arm64`) need a newer QEMU: Ubuntu 26.04 because
  of `tar` (Apptainer's own build scripts use it), Debian 13 because the Go compiler
  hangs there even with GODEBUG=asyncpreemptoff=1 (0% CPU for hours). Build them
  with a newer QEMU, registered only until the next reboot (about 55 minutes each):

  ```bash
  docker run --privileged --rm tonistiigi/binfmt --uninstall qemu-aarch64
  docker run --privileged --rm tonistiigi/binfmt --install arm64
  ARCHS=arm64 scripts/make-vendor-apptainer.sh ubuntu:26.04 debian:13
  ```

  Then go back to the system QEMU with the "C" flag (reboot, or):

  ```bash
  docker run --privileged --rm tonistiigi/binfmt --uninstall qemu-aarch64
  sudo systemctl restart systemd-binfmt
  sudo systemctl restart jupydo-qemu-credentials
  ```

  Do NOT restart `jupydo-qemu-credentials` while the temporary QEMU is registered:
  it would try to register again an interpreter that no longer exists on disk, and
  emulation would stop working until the next reboot.

The same limitation applies to users' emulated environments based on Ubuntu 26.04
(arm64 on amd64): commands like `tar` may fail there. Native machines are not
affected (the kernel implements those calls).

## 5. Not emulation: Ubuntu 26.04 arm64 and the gold linker

On arm64 Go links programs with the gold linker (`-fuse-ld=gold`). Ubuntu 26.04
moved gold out of `binutils` into its own package, `binutils-gold`: without it the
Apptainer build fails with "collect2: fatal error: cannot find 'ld'". The bundle
build installs `binutils-gold` wherever the distribution has it.

## 6. Apptainer does not run in emulated environments

Apptainer's starter (the program that creates its namespaces) cannot run under QEMU
user-mode emulation: "Failed to spawn stage 1" (tested with the QEMU of Ubuntu 24.04
and with the latest one from tonistiigi/binfmt). So the Apptainer module works only
in native environments (amd64 images on an amd64 server, arm64 images on an arm64
one); JupyDo refuses Apptainer for an emulated image, with a clear message.
From a native environment Apptainer can still run containers of the other
architecture, whose programs are then emulated by the kernel:

```bash
apptainer build --arch arm64 --fix-perms --sandbox alpine-arm64 docker://alpine:3.20
apptainer exec alpine-arm64 uname -m     # aarch64
```

Use a sandbox folder, not a .sif file: before opening a .sif of another architecture
Apptainer checks /proc/sys/fs/binfmt_misc, which Docker does not show inside
containers, so it refuses it ("the image's architecture (arm64) could not run on the
host's (amd64)") although the kernel would run it. Sandbox folders skip that check
(pkg/image/sif.go is the only place doing it, Apptainer 1.5.4); the kernel then
emulates the programs with the machine's QEMU (registered with the "F" flag, so it
works inside containers). `test-all.sh apptainer` marks emulated images N/A and tests
this case on the native ones. The arm64 Apptainer bundles are built and checked under emulation, but
running them needs a real arm64 machine: test them there once.

## 7. QEMU can crash by itself, now and then

During long, heavy work (e.g. compiling and loading R packages for 15 minutes) QEMU
itself sometimes crashes: the build log shows
`aarch64-binfmt-P: QEMU internal SIGSEGV` followed by `Segmentation fault`. It is not
reproducible: the same build run again passes (seen once with posit/r-base:4.4-focal
on arm64, which then passed). It cannot happen on a real arm64 machine. If a build
under emulation fails with that message, just run it again.

## 8. Emulation is slow

As a reference, on an amd64 laptop (22 threads): the Apptainer bundle takes about
3 minutes per amd64 distribution and about 30 minutes per arm64 one; an emulated
JupyDo environment is usable but much slower than a native one.
