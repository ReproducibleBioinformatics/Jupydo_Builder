# QEMU emulation: known problems and how the builder handles them

Images and bundles of the other architecture (arm64 on an amd64 machine, or vice
versa) run under QEMU user-mode emulation. It works, but it is slower and has a few
pitfalls. These are the ones found while building and testing the vendor bundles,
and what the builder does about each.

## 1. Setup: always the same QEMU, registered at every boot

The distributions' QEMU differs from machine to machine, and old versions crash on
some programs: the QEMU 8.2 of Ubuntu 24.04 crashed ("QEMU internal SIGSEGV") on
JupyDo's Python every time when emulating amd64 on an arm64 machine, and now and then
in long R compilations when emulating arm64 on an amd64 one. So the builder does not
use it: `scripts/setup-host.sh` takes the static QEMU of a pinned image
(`tonistiigi/binfmt`, QEMU 10.2.3), keeps it in `/usr/local/lib/jupydo/qemu`, and a
systemd service (`jupydo-qemu`, `scripts/lib/qemu-register.sh`) registers it at every
boot in place of any QEMU the system registers (an emulation enabled by hand with
`docker run --privileged tonistiigi/binfmt --install ...` lives only in memory and
disappears at the next reboot). Every machine of a large-scale test then emulates with
the same QEMU. Check with `head -3 /proc/sys/fs/binfmt_misc/qemu-aarch64` (on amd64) or
`qemu-x86_64` (on arm64): interpreter `/usr/local/lib/jupydo/qemu/...`, flags `POCF`.

## 2. sudo inside emulated containers: the "C" flag

Without the "C" (credentials) flag setuid programs such as `sudo` fail in emulated
containers with "effective uid is not 0". The `jupydo-qemu` service registers QEMU
with it (flags `POCF`; F makes the emulator work inside containers).
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

The `tar` of Ubuntu 26.04 uses system calls that older QEMU versions do not implement:
under the QEMU of Ubuntu/Pop!_OS 24.04 it failed with "Cannot open: Function not
implemented"; the Go compiler hung building Apptainer for Debian 13 arm64. The QEMU the
builder installs (10.2.3, see 1) has those calls. The Dockerfile also extracts archives
with `ADD` (done by Docker itself, outside the container) instead of running `tar` in
the image.

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

## 7. QEMU crashes: "QEMU internal SIGSEGV"

A build log with `x86_64-binfmt-P: QEMU internal SIGSEGV` or
`aarch64-binfmt-P: QEMU internal SIGSEGV` (followed by `Segmentation fault`) means
the distribution's QEMU is in use (its interpreter is under `/usr/libexec/qemu-binfmt/`),
not the builder's: run `sudo scripts/setup-host.sh` again, then the test. It cannot
happen on a real machine of that architecture.

## 8. Emulation is slow

As a reference, on an amd64 laptop (22 threads): the Apptainer bundle takes about
3 minutes per amd64 distribution and about 30 minutes per arm64 one; an emulated
JupyDo environment is usable but much slower than a native one.
