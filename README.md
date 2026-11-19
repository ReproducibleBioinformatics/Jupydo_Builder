# JupyDo builder

Turns **any Docker image** (Ubuntu, Debian, or a minimal BioContainers image) into a
**JupyDo environment**: a complete JupyterLab environment with the same, pinned JupyDo
stack in every image, without changing the image's own software and **without network**
during the build. [JupyDo](https://github.com/Vehx35/JupyDo) uses it every time a user
picks an image; it can also be used by hand.

Everything the build installs comes from **vendored bundles** (`vendor/`), made once on
the vendoring machine with the `make-vendor-*.sh` scripts and **published on Zenodo**
(`scripts/publish-zenodo.py`), from where JupyDo's `first_start.sh` downloads them
(current version: [10.5281/zenodo.24365831](https://doi.org/10.5281/zenodo.24365831)).

Developed by the **Reproducible Bioinformatics Lab**, University of Turin.

## Contents

- [What a JupyDo environment gets](#what-a-jupydo-environment-gets)
- [Supported images](#supported-images)
- [Optional modules](#optional-modules)
- [Build an image by hand](#build-an-image-by-hand)
- [The vendored bundles](#the-vendored-bundles)
- [Publishing on Zenodo](#publishing-on-zenodo)
- [Tests](#tests)
- [Security profiles](#security-profiles)
- [Emulation (other architecture)](#emulation-other-architecture)
- [Repository layout](#repository-layout)
- [License](#license)

## What a JupyDo environment gets

Built `FROM` the chosen image (named `jupydo/<image name>:<tag>`), it adds:

- **JupyDo's own Python** (`/opt/python4Jup`, a portable Python with exactly the packages
  of `lists/python-requirements.lock`): JupyterLab, the JupyterHub single-user server and
  the JupyterLab extensions, independent from any Python of the image;
- **kernels for the image's own languages**: a Jupyter kernel for every Python found in
  the image (ipykernel from `vendor/kernel-libs`, matched to each Python version) and for
  every R (the R kernel, compiled offline from a frozen CRAN snapshot, `vendor/r`);
- **build tools** (compilers, `make`, headers...) as an offline apt repository, so users
  can compile and install packages (`vendor/apt`);
- **the JupyDo entrypoint**: a personal account per user (name and UID given by JupyDo)
  with `sudo`; a home where only hidden files and folders are writable;
- **`jupydo-check`**: the check of the whole stack, run at the end of the build (the build
  fails if something is missing); JupyDo also runs it to decide whether an image is ready;
- **`jupydo-selftest`**: the environment self-test, as a terminal command.

**The image is never broken.** The build never removes a package of the image. When the
image has other versions of some packages than JupyDo's bundles, apt tries, in order:
1. the bundles alone (installing, or stepping packages back or forward to the bundle's
   versions, nothing removed);
2. if that is not enough and there is network, the distribution's archive too (the image's
   own apt sources) for the versions the bundles lack, nothing removed; what came from it is
   listed in `/opt/jupydo/apt-online.txt`;
3. if even that is not enough, the JupyDo packages that would remove packages of the image
   are left out (`/opt/jupydo/apt-skipped.txt`), and a module that cannot be added without
   removing packages of the image is left out (`/opt/jupydo/modules-skipped.txt`): the
   environment is built anyway, and `jupydo-check` shows a warning instead of a failure.

Labels record what was done: `org.jupydo.builder` (builder version: an image is ready only
if built by the current one), `org.jupydo.modules`, the platform, the kernel libraries.
Only the bundles of the image's distribution and architecture are sent to Docker.

## Supported images

- **Ubuntu** 16.04, 18.04, 20.04, 22.04, 24.04, 26.04 and **Debian** 12, 13
  (`lists/distros.txt`), on **amd64** and **arm64**. Distributions older than glibc 2.31
  (Ubuntu 16.04, 18.04) use the `python-legacy` bundle, built on ubuntu:16.04.
- **Minimal BioContainers images** (BusyBox + glibc, a conda environment in `/usr/local`,
  no package manager): converted first onto the vendored Debian 12 base
  (`Dockerfile.convert`, `vendor/bases`), keeping their `/usr/local` and environment
  variables, then built as usual.
- The distribution, the architecture and the Pythons and Rs of an image are detected
  automatically (`modules/detect-image.sh`).

## Optional modules

Each from its own self-contained bundle (`vendor/<module>/<platform>`); the image gets the
suffix `-<module>`:

| Module | What it adds |
|---|---|
| `rstudio` | RStudio Server, started by JupyterLab as the user (one launcher per R of the image), opening in `/sharedFolder` |
| `vscode` | code-server (VS Code in the browser) with its extensions, from the JupyterLab launcher |
| `desktop` | an XFCE desktop in the browser (TigerVNC), for graphical programs |
| `igv` | IGV-Web in a JupyterLab tab, reading the user's BAM/VCF files |
| `apptainer` | Apptainer, compiled from its official source for each distribution, with its helpers and the system packages it needs; runs inside the container with a dedicated AppArmor profile and seccomp filter |

## Build an image by hand

```bash
sudo scripts/setup-host.sh                      # once: Docker check, QEMU, AppArmor profile
scripts/build-image.sh rocker/r-ver:4.4.1      # -> jupydo/r-ver:4.4.1
scripts/build-image.sh ubuntu:24.04 jupydo/test:latest
MODULES="rstudio vscode" scripts/build-image.sh rocker/r-ver:4.4.1
PLATFORM=linux/arm64 scripts/build-image.sh ubuntu:24.04   # the other architecture (QEMU)
```

An image built by hand and one built by JupyDo are the same and interchangeable.
`setup-host.sh` checks Docker, installs QEMU emulation with the boot-time fix that makes
`sudo` work in emulated containers, and loads the Apptainer AppArmor profile; it can be
run again at any time.

## The vendored bundles

Made on the vendoring machine (each script checks and resumes; `ARCHS=amd64` limits the
architectures). Each bundle has `manifest.txt` (exact versions and sources),
`SHA256SUMS` and `.complete` (written last: an unfinished bundle is never used).

| Script | Bundle | Content |
|---|---|---|
| `make-vendor-python.sh` | `vendor/python/<arch>` | JupyDo's Python (`/opt/python4Jup`) with the locked packages; `VARIANT=legacy` → `vendor/python-legacy` for old distributions |
| `make-vendor-kernel-libs.sh` | `vendor/kernel-libs/<arch>/cp3XY` | ipykernel and dependencies for every Python version, binary only, for the oldest glibc possible |
| `make-vendor-r.py` | `vendor/r` | offline CRAN repositories for the R kernel, from frozen CRAN snapshots (sources, compiled by the image's own R) |
| `make-vendor-apt.sh` | `vendor/apt/<distro>-<version>-<arch>` | build tools with their complete dependency closure, as local apt repositories |
| `make-vendor-bases.sh` | `vendor/bases` | the Debian 12 base used to convert minimal BioContainers images |
| `make-vendor-rstudio.sh` | `vendor/rstudio/...` | RStudio Server and its dependencies, the JupyterLab launcher |
| `make-vendor-vscode.sh` | `vendor/vscode/...` | code-server, its extensions, the launcher |
| `make-vendor-desktop.sh` | `vendor/desktop/...` | XFCE, TigerVNC and dependencies, the launcher |
| `make-vendor-igv.sh` | `vendor/igv/...` | IGV-Web and its launcher |
| `make-vendor-apptainer.sh` | `vendor/apptainer/...` | Apptainer compiled per distribution, with its packages |
| `make-vendor-hub.sh` | `vendor/hub` | everything needed to **build the JupyDo hub image offline**: base image pinned by digest, Python wheels, Node.js, configurable-http-proxy, conntrack, and the sources of the Genome Index Service and of the JupyDo Assistant at a fixed commit (amd64 and arm64) |

The package lists are in `lists/` (`python-requirements.in` → `lock-python.sh` →
`python-requirements.lock`, `apt-*.txt`, `r-packages.txt`, `rstudio.txt`, `vscode*.txt`,
`desktop*.txt`, `igv*.txt`, `apptainer*.txt`, `distros.txt`, `distro-exceptions.txt`).
`vendor_list.txt` lists the files of a complete `vendor/`.

## Getting the bundles

On any machine, from a clone of this repository, download them from Zenodo (checked against
the record's SHA-256, resumable):

```bash
scripts/get-vendor.sh            # the record in zenodo.json, or: scripts/get-vendor.sh <record>
```

## Publishing on Zenodo

`scripts/publish-zenodo.py` puts on Zenodo, as a new version of the same record (a DOI per
version), one archive per bundle (`vendor-<bundle>.tar`), the builder source
(`jupydo-builder-src.tar.gz`), optionally the hub image (`--hub-image`), and `SHA256SUMS`:

```bash
python3 scripts/publish-zenodo.py --out ~/zenodo-files                    # 1. pack (checks every bundle is complete)
ZENODO_TOKEN=... python3 scripts/publish-zenodo.py --out ~/zenodo-files --upload   # 2. upload into a draft
```

then check the draft on Zenodo and publish it (or add `--publish`). `--sandbox` uses
sandbox.zenodo.org for trials. The record and its description are in `zenodo.json`: an
unpublished draft is filled (its metadata kept), a published record gets a new version.
After publishing, set the record id in JupyDo's `first_start.sh` (`JUPYDO_VENDOR_RECORD`):
installations and the GitHub build of the hub image then use that version.

## Tests

`scripts/test-all.sh` builds and checks images; for each one: **build** (offline + stack
check), **kernels** (starts the Python kernel, and the R kernel if there is R, and runs
`6*7`), **user** (the entrypoint creates a personal account with `sudo`), **compile** (a C
and a Fortran program compiled and run offline), plus the checks of the modules.

```bash
scripts/test-all.sh                  # everything
scripts/test-all.sh official         # the official image of every distribution, both architectures
scripts/test-all.sh real             # the real images of lists/test-images.txt
scripts/test-all.sh apptainer        # the Apptainer module on every distribution
scripts/test-all.sh big              # the large-scale test (lists/bigtest/)
```

In the large-scale test, the columns `removed` and `skipped` list the packages of the image
the build removed (always `-`) and the JupyDo packages it left out. Results go to `tests/results-<date>.tsv` (logs in `tests/logs/`; `RUN_DIR` keeps a run
apart). `pin-test-images.sh` pins the test images to their digests, so the tests always
run on the same images.

### Running the large-scale test on a server

On any Linux server with Docker (amd64 or arm64), with about 16 GB for the bundles plus
room for the images being tested (each one is removed after its test):

```bash
git clone https://github.com/ReproducibleBioinformatics/Jupydo_Builder.git && cd Jupydo_Builder
sudo scripts/setup-host.sh        # once: checks Docker, installs QEMU (the other architecture)
scripts/get-vendor.sh             # the bundles from Zenodo (about 16 GB, checked, resumable)
tmux new -d -s big 'scripts/bigtest/run-all.sh lists/bigtest/bigtest-2026-10-27-amd64.tsv lists/bigtest/bigtest-2026-10-27-arm64.tsv; bash'
```

It runs the list of the server's architecture natively, then the other list in emulation
(`ONLY=native` or `ONLY=emulated` for one part only; `EMULATED_LIMIT=n` for the first n
images of the emulated part). It can be stopped and started again: it goes on where it
stopped. Follow it with `tmux attach -t big` (detach with Ctrl-b d); the results are in
`tests/bigtest-<list arch>-on-<server arch>/big-results.tsv`, one row per image, with the
build log of each image in `logs/` next to it. JupyDo, if installed on the same server, is
not touched (test images are named `jupydo-test/...`), but shares the CPU, memory and disk.

**Large-scale test** (`scripts/bigtest/`): `make-lists.py` builds, from public registries
and with fixed rules, lists of the most used BioContainers, all StaPH-B images and the most
pulled Docker Hub bioinformatics images, pinned by digest; `arch-survey.py` reports which
architectures each image is published for; `run-all.sh` runs the list of this machine's
architecture natively and the other one in emulation, resumable (network failures are
tried again, images deleted from their registry are reported as such), each part in
`tests/bigtest-<list arch>-on-<machine arch>/big-results.tsv`.

## Security profiles

Only for containers with the Apptainer module (`security/`):

- `jupydo-apptainer.apparmor.in`: Docker's default AppArmor profile plus mount,
  pivot_root and user namespaces, adapted to the machine's AppArmor version and loaded by
  `load-apparmor-profile.sh` (JupyDo's `first_start.sh` runs it);
- `apptainer-seccomp.json`: Docker's seccomp profile plus the system calls Apptainer
  needs, generated by `make-apptainer-seccomp.py` from Docker's own profile.

## Emulation (other architecture)

Bundles and images of the other architecture are built and run under QEMU. Known problems
and how the builder handles each are in [docs/qemu-emulation.md](docs/qemu-emulation.md).

## Repository layout

```
Dockerfile              the JupyDo build of an image (FROM the chosen image)
Dockerfile.convert      conversion of minimal BioContainers images onto the Debian 12 base
modules/                entrypoint, stack check, self-test, image detection, kernel
                        registration, module installers (rstudio, vscode, desktop, igv, apptainer)
scripts/                build-image.sh, make-vendor-*, publish-zenodo.py, tests, setup-host.sh
scripts/lib/            helpers run inside the bundle builds, smoke tests
scripts/bigtest/        the large-scale test
lists/                  package lists, locks, distributions, test and large-scale lists
security/               AppArmor and seccomp profiles (Apptainer module)
docs/                   notes (QEMU emulation)
zenodo.json             the Zenodo record and its description
vendor/                 the bundles (not in the repository: from make-vendor-* or Zenodo)
```

## License

This project is licensed under the **BSD 3-Clause License**. See the [LICENSE](LICENSE)
file. The vendored bundles contain third-party software, each under its own license
(see each bundle's `manifest.txt`).

## Authors

* **Francesco Maria Antonio Micocci** - *University of Turin*
* **Luca Alessandri** - *University of Turin*
* Developed by the **Reproducible Bioinformatics Lab**, University of Turin.
