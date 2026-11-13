"""
Run in the image build by JupyDo's own Python (/opt/python4Jup), as root.

Makes every Python and R of the image (found by modules/detect-image.sh in the
original image: selected/kernels.txt) a Jupyter kernel, without changing them:
  - a Python with ipykernel: used as it is;
  - a Python without it: started with the kernel libraries of its version
    (/opt/jupydo/kernel-libs/cp3XY/site) appended at the END of its path, so the
    image's own packages always come first;
  - an R with IRkernel: used as it is;
  - an R without it: IRkernel is compiled from the CRAN snapshot for that R version
    into a separate library (/opt/jupydo/r-kernel-libs/<name>), appended at the end
    of its library paths only when it runs as a kernel.
Each kernel is then started and must compute 6 * 7: one that does not is removed and
reported (never a broken kernel in the menu). Kernels the image's authors left that
start a bare "python3" (which Jupyter would run with JupyDo's Python) are removed when
they duplicate a JupyDo kernel, otherwise given the full path. JupyDo's own Python is not a kernel:
it only runs JupyterLab.
Result: /opt/jupydo/kernels.json (read by jupydo-check and jupydo-selftest).

Usage: python3 register-kernels.py <kernels.txt> <r snapshots dir>
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time

PREFIX = "/opt/python4Jup"
KERNELS_DIR = os.path.join(PREFIX, "share", "jupyter", "kernels")
KERNEL_LIBS = "/opt/jupydo/kernel-libs"
R_KERNEL_LIBS = "/opt/jupydo/r-kernel-libs"
RESULT = "/opt/jupydo/kernels.json"
START_TIMEOUT = int(os.environ.get("JUPYDO_KERNEL_TIMEOUT", "300"))  # emulated builds are slow


def log(text):
    print("[kernels] " + text, flush=True)


def slug(path):
    return re.sub(r"[^a-z0-9]+", "-", path.lower()).strip("-")


IDLE_TIMEOUT = int(os.environ.get("JUPYDO_IDLE_TIMEOUT", "1800"))  # seconds without any output


def run(cmd, idle_timeout=IDLE_TIMEOUT, env=None):
    """Run cmd and return its output (like subprocess.run with capture_output).
    No limit on the total time: a long job that keeps working (e.g. compiling
    IRkernel under emulation, much slower) is never stopped. It is stopped only if
    it prints nothing at all for idle_timeout seconds: then it is stuck."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
    out, err = [], []
    last = [time.monotonic()]

    def reader(stream, sink):
        for line in stream:
            sink.append(line)
            last[0] = time.monotonic()

    threads = [threading.Thread(target=reader, args=(proc.stdout, out), daemon=True),
               threading.Thread(target=reader, args=(proc.stderr, err), daemon=True)]
    for t in threads:
        t.start()
    while proc.poll() is None:
        if time.monotonic() - last[0] > idle_timeout:
            proc.kill()
            proc.wait()
            for t in threads:
                t.join(5)
            err.append("ERROR: stopped: no output for {} seconds (stuck)\n".format(idle_timeout))
            return subprocess.CompletedProcess(cmd, 124, "".join(out), "".join(err))
        time.sleep(1)
    for t in threads:
        t.join()
    return subprocess.CompletedProcess(cmd, proc.returncode, "".join(out), "".join(err))


def hide_jupydo_python():
    """JupyDo's Python runs JupyterLab only: no kernel for it, not even the one
    JupyterLab would add by itself (ensure_native_kernel)."""
    shutil.rmtree(os.path.join(KERNELS_DIR, "python3"), ignore_errors=True)
    # In jupyter_server_config.json: the files in jupyter_server_config.d/ are read
    # only to enable extensions, any other setting there is ignored.
    etc = os.path.join(PREFIX, "etc", "jupyter")
    os.makedirs(etc, exist_ok=True)
    path = os.path.join(etc, "jupyter_server_config.json")
    conf = {}
    if os.path.isfile(path):
        with open(path) as f:
            conf = json.load(f)
    conf.setdefault("KernelSpecManager", {})["ensure_native_kernel"] = False
    with open(path, "w") as f:
        json.dump(conf, f, indent=2)
    try:  # left by older builders, where it had no effect
        os.remove(os.path.join(etc, "jupyter_server_config.d", "jupydo-kernels.json"))
    except FileNotFoundError:
        pass


def glibcxx_level(path):
    """Highest GLIBCXX_3.4.N version a libstdc++ provides (N; -1 if unreadable)."""
    try:
        with open(path, "rb") as f:
            found = re.findall(rb"GLIBCXX_3\.4\.(\d+)", f.read())
        return max(int(n) for n in found) if found else -1
    except OSError:
        return -1


def write_spec(name, spec, files_from=None):
    d = os.path.join(KERNELS_DIR, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for f in ("logo-32x32.png", "logo-64x64.png", "logo-svg.svg"):
        if files_from and os.path.isfile(os.path.join(files_from, f)):
            shutil.copy(os.path.join(files_from, f), d)
    with open(os.path.join(d, "kernel.json"), "w") as f:
        json.dump(spec, f, indent=1)
    return d


def test_kernel(name, language):
    """Start the kernel for real and run 6 * 7. Returns None if it works, else the error."""
    from jupyter_client.kernelspec import KernelSpecManager
    from jupyter_client.manager import KernelManager
    code = "print(6 * 7)" if language == "python" else "cat(6 * 7)"
    km = KernelManager(kernel_name=name, kernel_spec_manager=KernelSpecManager(ensure_native_kernel=False))
    errlog = tempfile.TemporaryFile(mode="w+")  # what the kernel prints if it dies
    try:
        km.start_kernel(stderr=errlog)
        kc = km.client()
        kc.start_channels()
        kc.wait_for_ready(timeout=START_TIMEOUT)
        msg_id = kc.execute(code)
        output = []
        while True:
            msg = kc.get_iopub_msg(timeout=START_TIMEOUT)
            if msg["parent_header"].get("msg_id") != msg_id:
                continue
            kind, content = msg["msg_type"], msg["content"]
            if kind == "stream":
                output.append(content["text"])
            elif kind == "execute_result":
                output.append(content["data"].get("text/plain", ""))
            elif kind == "error":
                return "{}: {}".format(content.get("ename"), content.get("evalue"))
            elif kind == "status" and content["execution_state"] == "idle":
                break
        return None if "42" in "".join(output) else "unexpected output: " + "".join(output)[-200:]
    except Exception as e:
        errlog.seek(0)
        lines = [l for l in errlog.read().splitlines() if l.strip() and "WARNING" not in l]
        said = (" | kernel output: " + " / ".join(lines[-12:])[-1500:]) if lines else ""
        return "{}: {}{}".format(type(e).__name__, str(e)[-300:], said)
    finally:
        try:
            km.shutdown_kernel(now=True)
        except Exception:
            pass
        errlog.close()


def python_kernel(path, version):
    name = "py-" + slug(path)
    display = "Python {} ({})".format(version, path)
    major, minor = (int(x) for x in version.split(".")[:2])
    if (major, minor) < (3, 8):
        return None, display, "Python {} is too old for a Jupyter kernel (3.8 or newer)".format(version)
    if run([path, "-c", "import ipykernel"]).returncode == 0:
        variants = [("its own ipykernel", [path, "-m", "ipykernel_launcher", "-f", "{connection_file}"])]
    else:
        # a free-threaded build (no GIL, "3.13t") loads only modules compiled for it:
        # the kernel libraries are for the normal build
        if run([path, "-c", "import sys, sysconfig; sys.exit(0 if sysconfig.get_config_var('Py_GIL_DISABLED') else 1)"]).returncode == 0:
            return None, display, "Python {} is a free-threaded build (no GIL): no kernel libraries for it".format(version)
        libs = os.path.join(KERNEL_LIBS, "cp{}{}".format(major, minor), "site")
        if not os.path.isdir(libs):
            return None, display, "no kernel libraries for Python {}".format(version)
        start = "from ipykernel import kernelapp; kernelapp.launch_new_instance()"
        variants = [  # image packages first; if that mix fails, kernel libraries first
            ("kernel libraries after its packages",
             [path, "-c", "import sys; sys.path.append({!r}); {}".format(libs, start), "-f", "{connection_file}"]),
            ("kernel libraries before its packages",
             [path, "-c", "import sys; sys.path.insert(1, {!r}); {}".format(libs, start), "-f", "{connection_file}"]),
        ]
    errors = []
    for how, argv in variants:
        write_spec(name, {"argv": argv, "display_name": display, "language": "python",
                          "metadata": {"jupydo": {"interpreter": path, "how": how}}})
        error = test_kernel(name, "python")
        if error is None:
            return name, display, None
        errors.append("{}: {}".format(how, error))
    shutil.rmtree(os.path.join(KERNELS_DIR, name), ignore_errors=True)
    return None, display, "; ".join(errors)


def r_snapshot(r_version, snapshots_dir):
    """The CRAN snapshot for this R version (snapshots.txt: name date rule, first match)."""
    def ver(text):
        return tuple(int(x) for x in re.findall(r"\d+", text)[:3])
    v = ver(r_version)
    with open(os.path.join(snapshots_dir, "snapshots.txt")) as f:
        for line in f:
            parts = line.split()
            if len(parts) < 3:
                continue
            m = re.match(r"(<=|>=|==|<|>)([\d.]+)", parts[2])
            if not m:
                continue
            op, limit = m.group(1), ver(m.group(2))
            if {"<": v < limit, "<=": v <= limit, ">": v > limit, ">=": v >= limit, "==": v == limit}[op]:
                return parts[0]
    return None


R_MIN = (3, 5)   # an older R whose kernel does not work is skipped, the build goes on


def r_too_old(version, error):
    """The error of an R kernel, said as "too old" (not fatal) for an R older than R_MIN."""
    try:
        old = tuple(int(x) for x in version.split(".")[:2]) < R_MIN
    except ValueError:
        old = False
    return "R {} is too old for a Jupyter kernel ({}.{} or newer): {}".format(version, *R_MIN, error) if old else error


def r_kernel(path, version, snapshots_dir):
    name, display, error = r_kernel_try(path, version, snapshots_dir)
    return name, display, (r_too_old(version, error) if error else error)


def r_kernel_try(path, version, snapshots_dir):
    name = "ir-" + slug(path)
    display = "R {} ({})".format(version, path)
    rscript = os.path.join(os.path.dirname(path), "Rscript")
    if not os.path.exists(rscript):
        rscript = None
    has = run([path, "--slave", "-e", 'quit(status = as.integer(!requireNamespace("IRkernel", quietly = TRUE)))'])
    lib = None
    spec_env = {}   # environment of the kernel (e.g. the libstdc++ it needs)
    if has.returncode == 0:
        main = "IRkernel::main()"
        how = "its own IRkernel"
    else:
        snapshot = r_snapshot(version, snapshots_dir)
        if snapshot is None:
            return None, display, "no CRAN snapshot for R {}".format(version)
        lib = os.path.join(R_KERNEL_LIBS, slug(path))
        os.makedirs(lib, exist_ok=True)
        env = dict(os.environ)
        # R from conda is set up for conda's compilers. If they are not in the image, or
        # they cannot compile even a minimal C file the way R compiles a package (e.g. a
        # BioContainer converted to Debian, where they are present without their own
        # system headers and mix Debian's with theirs: "stdlib.h: expected ',' or ';'
        # before '__attribute_alloc_align__'"), the system compilers are used.
        def conda_cc_works(cc):
            """Compile, as R compiles a package (its flags, R.h), a minimal C file."""
            if not cc or shutil.which(cc[0]) is None:
                return False
            flags = []
            for what in ("--cppflags", "CPPFLAGS", "CFLAGS"):
                flags += config_value(path, what).split()
            d = tempfile.mkdtemp()
            with open(os.path.join(d, "t.c"), "w") as f:
                f.write("#include <R.h>\n#include <stdlib.h>\nint main(void) { return 0; }\n")
            ok = run(cc + flags + ["-c", os.path.join(d, "t.c"), "-o", os.path.join(d, "t.o")]).returncode == 0
            shutil.rmtree(d, ignore_errors=True)
            return ok
        prefix = os.path.dirname(os.path.dirname(path))
        conda_r = os.path.isdir(os.path.join(prefix, "conda-meta"))
        cc = config_value(path, "CC").split()
        # R from conda always uses the system compilers: conda's compile for the glibc
        # of their own sysroot, which can be newer than the system's (rlang.so needing
        # GLIBC_2.38 on Debian 12, glibc 2.36), and the kernel runs on the system's glibc
        if (conda_r and shutil.which("gcc")) or not conda_cc_works(cc):
            makevars = os.path.join(tempfile.mkdtemp(), "Makevars")
            # Only the program is replaced: the options R gives with it are kept (R 4.5+
            # compiles C as C23, "-std=gnu23": without it its headers have no Rboolean).
            # A C23 option the system gcc does not know by that name gets its older one.
            def system_tool(var, program):
                words = config_value(path, var).split()
                if not words or words[0].startswith("ERROR"):
                    return program
                opts = []
                for w in words[1:]:
                    if w in ("-std=gnu23", "-std=c23") and run([program, w, "-x", "c", "-E", "/dev/null"]).returncode != 0:
                        w = w.replace("23", "2x")
                    opts.append(w)
                # R 3.x gives no C++ standard (its compiler then defaulted to C++98/14);
                # today's g++ defaults to C++17, which old Rcpp headers do not compile with
                if program == "g++" and not any(o.startswith("-std=") for o in opts) \
                        and version.split(".")[0] in ("2", "3"):
                    opts.append("-std=gnu++14")
                return " ".join([program] + opts)
            # R built with a newer C compiler (R 4.5+ from conda, gcc 15) declares its
            # Rboolean with a C23 feature older system compilers lack ("enum : int", gcc
            # 13+; Debian 12 has gcc 12): its Rconfig.h then says HAVE_ENUM_BASE_TYPE and
            # Boolean.h stops at that line. A copy of Rconfig.h without it is put first
            # in the C compiler's include path: the plain enum, int-sized as well (R
            # guarantees an int base type), so the packages stay compatible with R.
            cc = system_tool("CC", "gcc")
            rinc = run([path, "--slave", "-e", "cat(R.home('include'))"]).stdout.strip()
            rconfig = os.path.join(rinc, "Rconfig.h")
            if os.path.isfile(rconfig) and "HAVE_ENUM_BASE_TYPE" in open(rconfig).read():
                probe_c = os.path.join(tempfile.mkdtemp(), "enum_base.c")
                with open(probe_c, "w") as f:
                    f.write("typedef enum : int { A = 0 } t;\n")
                probe = run(cc.split() + ["-fsyntax-only", probe_c])
                if probe.returncode != 0:
                    override = tempfile.mkdtemp(prefix="jupydo-rconfig-")
                    with open(rconfig) as src, open(os.path.join(override, "Rconfig.h"), "w") as dst:
                        for line in src:
                            dst.write("/* JupyDo: removed for an older C compiler */\n" if "HAVE_ENUM_BASE_TYPE" in line
                                      and line.lstrip().startswith("#define") else line)
                    cc = "{} -I{}".format(cc, override)
                    log("  {}: the system C compiler has no C23 'enum : int': R's Rboolean as a plain enum".format(path))
            tools = [("CC", "gcc"), ("CXX", "g++"), ("CXX11", "g++"), ("CXX14", "g++"), ("CXX17", "g++"),
                     ("CXX20", "g++"), ("FC", "gfortran"), ("F77", "gfortran")]
            with open(makevars, "w") as f:
                # the whole toolchain: also the archiver, or packages that build a static
                # library (e.g. jsonlite) call conda's <arch>-conda-linux-gnu-ar
                f.write("".join("{}={}\n".format(var, cc if var == "CC" else system_tool(var, prog))
                                for var, prog in tools) +
                        "AR=ar\nRANLIB=ranlib\n"
                        # old sources (e.g. rlang of an old snapshot) define the same
                        # variables in several files: gcc 10+ refuses it without -fcommon
                        "CFLAGS += -fcommon\n")
            env["R_MAKEVARS_USER"] = makevars
            log("  {}: {}, using the system ones".format(path, "R from conda: its compilers target its own glibc"
                                                          if conda_r else "its compilers are not usable here"
                                                          " (missing, or without their system headers)"))
            # Packages in C++ (ZeroMQ of pbdZMQ...) now need the system's libstdc++; R from
            # conda loads its own, which can be older (R 3.3: "undefined symbol
            # _ZSt28__throw_bad_array_new_lengthv"). The newer of the two is loaded first,
            # while compiling and in the kernel (libstdc++ is backward compatible).
            sys_cxx = run(["g++", "-print-file-name=libstdc++.so.6"]).stdout.strip()
            r_cxx = os.path.join(prefix, "lib", "libstdc++.so.6")
            if conda_r and os.path.isabs(sys_cxx) and os.path.isfile(sys_cxx) and os.path.isfile(r_cxx) \
                    and glibcxx_level(sys_cxx) > glibcxx_level(r_cxx):
                sys_cxx = os.path.realpath(sys_cxx)
                env["LD_PRELOAD"] = sys_cxx
                spec_env["LD_PRELOAD"] = sys_cxx
                log("  {}: its libstdc++ is older than the system's: the system's is loaded first ({})".format(path, sys_cxx))
        # Tried in order, each only if the one before failed, so an image that built the
        # way before still builds exactly the same:
        #  1. the way before: R from conda builds pbdZMQ (IRkernel's link to Jupyter) with
        #     its own copy of ZeroMQ, any other R links it to the system's ZeroMQ;
        #  2. R from conda: pbdZMQ linked to the system's ZeroMQ instead (its own copy
        #     can pick headers of the image's conda environment, e.g. its assert.h);
        #  3. the IRkernel packages installed apart from the image's R packages (an old
        #     one of the image, e.g. backports, can be too old for the others).
        snap = os.path.join(snapshots_dir, snapshot)
        internal = ", configure.args = c(pbdZMQ = '--enable-internal-zmq')"
        if conda_r:
            attempts = [(internal, ".libPaths()", " (conda R: pbdZMQ with its own ZeroMQ)"),
                        ("", ".libPaths()", " (pbdZMQ with the system's ZeroMQ)")]
        else:
            attempts = [("", ".libPaths()", "")]
        attempts.append((attempts[-1][0], ".Library", " (apart from the image's R packages)"))
        # for that last one also the R processes the installation starts (R CMD INSTALL)
        # must not see the image's libraries: two Rs of an image can share one
        # site-library, built for the other R ("undefined symbol: EXTPTR_PROT")
        no_libs = tempfile.mkdtemp(prefix="jupydo-no-libs-")
        for k, (conf, libs, what) in enumerate(attempts):
            step_env = env if libs != ".Library" else dict(env, R_LIBS=lib, R_LIBS_SITE=no_libs, R_LIBS_USER=no_libs)
            shutil.rmtree(lib, ignore_errors=True)
            os.makedirs(lib, exist_ok=True)
            log("  {}: compiling IRkernel from the '{}' CRAN snapshot{}{}".format(
                path, snapshot, what, "" if k == 0 else " (attempt {})".format(k + 1)))
            install = run([path, "--slave", "-e",
                           ".libPaths(c({lib!r}, {libs})); install.packages('IRkernel', lib = {lib!r}, "
                           "repos = 'file://{snap}', type = 'source'{conf}); library(IRkernel)".format(
                               lib=lib, libs=libs, snap=snap, conf=conf)], env=step_env)
            if install.returncode == 0:
                break
        if install.returncode != 0:
            # the real error is above R's final warnings: show the end of the output in the build log
            lines = (install.stdout + install.stderr).splitlines()
            log("  {}: IRkernel compilation output (last 80 lines):\n    ".format(path) + "\n    ".join(lines[-80:]))
            # a library that does not load: R gives the reason on the lines after the
            # name, often far above the last 80 lines
            for i, l in enumerate(lines):
                if "unable to load shared object" in l or "namespace load failed" in l:
                    log("  {}: load error:\n    ".format(path) + "\n    ".join(lines[i:i + 4]))
                    break
            shutil.rmtree(lib, ignore_errors=True)
            # R wraps long messages: join the error line with the next one
            idx = next((i for i, l in enumerate(lines) if "ERROR" in l or "error:" in l), None)
            first = " ".join(l.strip() for l in lines[idx:idx + 4]) if idx is not None else (lines[-1] if lines else "")
            return None, display, "IRkernel could not be compiled: " + first.strip()[:700]
        main = ".libPaths(c(.libPaths(), {!r})); IRkernel::main()".format(lib)
        how = "IRkernel in " + lib
    logos = run([path, "--slave", "-e", "cat(system.file('kernelspec', package = 'IRkernel'{}))".format(
        ", lib.loc = c(.libPaths(), {!r})".format(lib) if lib else "")]).stdout.strip()
    spec = {"argv": [path, "--slave", "-e", main, "--args", "{connection_file}"],
            "display_name": display, "language": "R",
            "metadata": {"jupydo": {"interpreter": path, "how": how}}}
    if spec_env:
        spec["env"] = spec_env
    write_spec(name, spec, files_from=logos or None)
    error = test_kernel(name, "R")
    if error is not None and lib:
        # The image's R packages come first in the kernel (users keep their versions);
        # if an old one of them stops IRkernel (e.g. "namespace 'rlang' 0.1.2 is already
        # loaded, but >= ... is required"), the kernel's own packages come first instead.
        log("  {}: the kernel does not start with the image's R packages first ({}): "
            "its own packages first".format(path, error[:150]))
        spec["argv"][3] = ".libPaths(c({!r}, .libPaths())); IRkernel::main()".format(lib)
        spec["metadata"]["jupydo"]["how"] = how + " (its packages first)"
        write_spec(name, spec, files_from=logos or None)
        error = test_kernel(name, "R")
    if error is None:
        return name, display, None
    shutil.rmtree(os.path.join(KERNELS_DIR, name), ignore_errors=True)
    return None, display, error


def image_kernel_dirs():
    """Kernels the image's authors left (outside JupyDo's own kernel folder): the ones
    JupyterLab would list, plus the users' homes (seen only when the user runs it)."""
    import glob
    from jupyter_client.kernelspec import KernelSpecManager
    dirs = set(KernelSpecManager(ensure_native_kernel=False).find_kernel_specs().values())
    for pattern in ("/home/*/.local/share/jupyter/kernels/*", "/root/.local/share/jupyter/kernels/*"):
        dirs.update(d for d in glob.glob(pattern) if os.path.isfile(os.path.join(d, "kernel.json")))
    own = os.path.realpath(KERNELS_DIR) + os.sep
    return sorted(d for d in dirs if not (os.path.realpath(d) + os.sep).startswith(own)
                  and "/site-packages/ipykernel/" not in d)


def fix_image_kernels(results):
    """A kernel of the image started by a bare "python"/"python3"/"python3.X" (no path)
    would run JupyDo's own Python: Jupyter replaces those names with the Python that
    runs it. Such a kernel is removed when its Python is already a JupyDo kernel (the
    same interpreter, with the same libraries: a duplicate); otherwise its command gets
    the full path of the Python that name means in the image."""
    ours = {os.path.realpath(r["interpreter"]): r["display_name"] for r in results
            if r["ok"] and r["language"] == "python"}
    for d in image_kernel_dirs():
        spec_file = os.path.join(d, "kernel.json")
        try:
            with open(spec_file) as f:
                spec = json.load(f)
        except (OSError, ValueError):
            continue
        argv = spec.get("argv") or []
        if not argv or not re.fullmatch(r"python(\d+(\.\d+)?)?", argv[0]):
            continue
        real = shutil.which(argv[0])   # the image's PATH (JupyDo's Python is never on it)
        real = os.path.realpath(real) if real else None
        if real in ours:
            if spec.get("env"):
                log("  WARN image kernel {} set its own environment {}: lost with it".format(d, sorted(spec["env"])))
            shutil.rmtree(d, ignore_errors=True)
            log("  image kernel {} ('{}' = {}): removed, same Python as kernel '{}'".format(
                d, argv[0], real, ours[real]))
        elif real:
            spec["argv"] = [real] + argv[1:]
            with open(spec_file, "w") as f:
                json.dump(spec, f, indent=1)
            log("  image kernel {}: '{}' written as {}".format(d, argv[0], real))
        else:
            shutil.rmtree(d, ignore_errors=True)
            log("  WARN image kernel {}: '{}' is not on the image's PATH: removed".format(d, argv[0]))


def config_value(path, var, env=None):
    """R CMD config <var> of this R: the last line of its output (an image's R_HOME for
    another R makes R print "WARNING: ignoring environment value of R_HOME" first)."""
    lines = [l for l in run([path, "CMD", "config", var], env=env).stdout.splitlines() if l.strip()]
    return lines[-1].strip() if lines else ""


def main():
    # An R_HOME set by the image is for one R only: with several Rs (or a conda R next
    # to the system one) the others warn and the packages they build start the wrong
    # R ("lazy loading failed"). Every R finds its own home.
    os.environ.pop("R_HOME", None)
    found, snapshots_dir = sys.argv[1], sys.argv[2]
    os.makedirs(KERNELS_DIR, exist_ok=True)
    os.makedirs(os.path.dirname(RESULT), exist_ok=True)
    hide_jupydo_python()
    results = []
    for line in open(found):
        parts = line.split()
        if len(parts) < 3 or parts[0] not in ("PY", "R"):
            continue
        kind, path, version = parts[0], parts[1], parts[2]
        log("{} {} {}".format("Python" if kind == "PY" else "R", version, path))
        if kind == "PY":
            name, display, error = python_kernel(path, version)
        else:
            name, display, error = r_kernel(path, version, snapshots_dir)
        results.append({"language": "python" if kind == "PY" else "R", "interpreter": path, "version": version,
                        "kernel": name, "display_name": display, "ok": error is None, "error": error})
        log("  -> " + ("kernel '{}'".format(display) if error is None else "NO kernel: " + error))
    fix_image_kernels(results)
    with open(RESULT, "w") as f:
        json.dump(results, f, indent=1)
    ok = [r for r in results if r["ok"]]
    log("{} kernel(s): {} Python, {} R; {} not usable".format(
        len(ok), sum(r["language"] == "python" for r in ok), sum(r["language"] == "R" for r in ok),
        len(results) - len(ok)))
    # a Python or R of the image that did not become a kernel stops the build: an
    # image that looks ready but has lost one of its kernels must never be produced.
    # Skipped on purpose: a Python too old for Jupyter (< 3.8), a free-threaded Python.
    failed = [r for r in results if not r["ok"]
              and not any(w in (r["error"] or "") for w in ("is too old", "is a free-threaded build"))]
    if failed:
        for r in failed:
            log("ERROR: {} {} ({}) did not become a kernel: {}".format(
                "Python" if r["language"] == "python" else "R", r["version"], r["interpreter"], r["error"]))
        log("ERROR: build stopped: fix the cause above, or remove this interpreter from the image")
        sys.exit(1)


if __name__ == "__main__":
    main()
