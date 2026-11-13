"""
jupydo-selftest: checks that this JupyDo environment works. Runs in every image
(also without Python or R): it uses JupyDo's own Python, by its full path.

Checks what this environment has, and says SKIP for what it does not have:
  kernels (every one is started and computes 6 * 7), sudo, compilers, storage,
  network, Apptainer, the job queue and a GPU job.
Usage:  jupydo-selftest [--no-jobs] [--no-gpu] [--no-apptainer] [--no-network] [--wait MINUTES]
Exit code 1 if something FAILED.
"""
import argparse
import sys
import json
import os
import platform
import shutil
import subprocess
import tempfile
import time
import urllib.request

SELFTEST_DIR = "/sharedFolder/.jupydo-selftest"
JOBQUEUE_CLI = "/opt/jobqueue/jobqueue_cli.py"
RESULTS = []


class Skip(Exception):
    """Not available in this environment."""


class Warn(Exception):
    """Works partly, or could not be verified."""


def check(name, function):
    try:
        status, detail = "PASS", function() or ""
    except Skip as e:
        status, detail = "SKIP", str(e)
    except Warn as e:
        status, detail = "WARN", str(e)
    except Exception as e:
        status, detail = "FAIL", "{}: {}".format(type(e).__name__, e)
    RESULTS.append((name, status, str(detail)))
    print("{:4}  {}: {}".format(status, name, detail), flush=True)


def run(command, timeout=120, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, timeout=timeout, **kwargs)
    if result.returncode != 0:
        raise RuntimeError((result.stdout + result.stderr).strip()[-400:] or "exit code {}".format(result.returncode))
    return result.stdout.strip()


def environment():
    info = {}
    for line in open("/etc/os-release"):
        key, _, value = line.strip().partition("=")
        info[key] = value.strip('"')
    modules = os.environ.get("JUPYDO_MODULES", "").strip() or "none"
    return "{}, {}, glibc {}, modules: {}".format(info.get("PRETTY_NAME", "?"), platform.machine(),
                                                 platform.libc_ver()[1], modules)


def user():
    return "{} (uid {}), home {}".format(run(["id", "-un"]), os.getuid(), os.path.expanduser("~"))


def kernel_list():
    from jupyter_client.kernelspec import KernelSpecManager
    return sorted(KernelSpecManager(ensure_native_kernel=False).get_all_specs().items())


def start_kernel(name, spec):
    from jupyter_client.kernelspec import KernelSpecManager
    from jupyter_client.manager import KernelManager
    code = {"python": "print(6 * 7)", "r": "cat(6 * 7)", "julia": "println(6 * 7)"}.get(spec["spec"]["language"].lower())
    if code is None:
        raise Skip("language {}: no test code for it".format(spec["spec"]["language"]))
    km = KernelManager(kernel_name=name, kernel_spec_manager=KernelSpecManager(ensure_native_kernel=False))
    try:
        km.start_kernel()
        kc = km.client()
        kc.start_channels()
        kc.wait_for_ready(timeout=180)
        msg_id = kc.execute(code)
        output = []
        while True:
            msg = kc.get_iopub_msg(timeout=180)
            if msg["parent_header"].get("msg_id") != msg_id:
                continue
            if msg["msg_type"] == "stream":
                output.append(msg["content"]["text"])
            elif msg["msg_type"] == "error":
                raise RuntimeError(msg["content"].get("ename", "") + ": " + msg["content"].get("evalue", ""))
            elif msg["msg_type"] == "status" and msg["content"]["execution_state"] == "idle":
                break
    finally:
        km.shutdown_kernel(now=True)
    if "42" not in "".join(output):
        raise RuntimeError("unexpected output {!r}".format("".join(output)))
    return spec["spec"].get("display_name", name) + ": 6 * 7 = 42"


def kernels_found():
    report = "/opt/jupydo/kernels.json"
    notes = []
    if os.path.exists(report):
        for k in json.load(open(report)):
            if not k["ok"]:
                notes.append("{}: not a kernel ({})".format(k["display_name"], k["error"]))
    specs = kernel_list()
    if not specs:
        raise Warn("no kernels: this image has no Python or R usable as a kernel (the terminal works)"
                   + ("; " + "; ".join(notes) if notes else ""))
    detail = "{} kernel(s): {}".format(len(specs), ", ".join(s["spec"].get("display_name", n) for n, s in specs))
    if notes:
        raise Warn(detail + "; " + "; ".join(notes))
    return detail


def sudo():
    if not shutil.which("sudo"):
        raise RuntimeError("sudo not installed")
    run(["sudo", "-n", "true"])
    return "passwordless sudo works"


def compilers():
    work = tempfile.mkdtemp()
    sources = {"C": ("t.c", '#include <stdio.h>\nint main(void){printf("%d\\n", 6*7);return 0;}\n', "gcc"),
               "C++": ("t.cpp", "#include <iostream>\nint main(){std::cout << 6*7 << std::endl;}\n", "g++"),
               "Fortran": ("t.f90", "program t\n  print '(i0)', 6*7\nend program t\n", "gfortran")}
    for language, (filename, text, compiler) in sources.items():
        if not shutil.which(compiler):
            raise RuntimeError(compiler + " missing")
        with open(os.path.join(work, filename), "w") as f:
            f.write(text)
        exe = os.path.join(work, "t_" + compiler.replace("+", "p"))
        run([compiler, os.path.join(work, filename), "-o", exe])
        if run([exe]) != "42":
            raise RuntimeError(language + " program printed something else")
    return "C, C++, Fortran compiled and run"


def shared_folder():
    if not os.path.isdir("/sharedFolder"):
        raise RuntimeError("/sharedFolder missing")
    os.makedirs(SELFTEST_DIR, exist_ok=True)
    path = os.path.join(SELFTEST_DIR, "write_test.txt")
    with open(path, "w") as f:
        f.write("ok")
    usage = shutil.disk_usage("/sharedFolder")
    detail = "writable, {:.0f} GB free of {:.0f} GB".format(usage.free / 1e9, usage.total / 1e9)
    if usage.free / 1e9 < 5:
        raise Warn(detail + " (little space left)")
    return detail


def home_folders():
    for d in (".local", ".cache", ".config"):
        path = os.path.join(os.path.expanduser("~"), d)
        if not os.access(path, os.W_OK):
            raise RuntimeError(path + " is not writable")
    return "~/.local, ~/.cache, ~/.config writable (pip --user, caches)"


def network(enabled):
    if not enabled:
        raise Skip("--no-network")
    try:
        with urllib.request.urlopen("https://pypi.org/simple/pip/", timeout=15) as r:
            r.read(100)
    except Exception as e:
        raise Warn("PyPI not reachable ({}): installing from the internet will not work".format(e))
    return "PyPI reachable (pip / conda / install.packages can download)"


def apptainer(enabled):
    wanted = "apptainer" in os.environ.get("JUPYDO_MODULES", "").split()
    if not shutil.which("apptainer"):
        if wanted:
            raise RuntimeError("built with the Apptainer module but apptainer is missing")
        raise Skip("no Apptainer here (create an environment with the Apptainer option)")
    version = run(["apptainer", "--version"])
    if not enabled:
        return version + " (container not run: --no-apptainer)"
    env = dict(os.environ, APPTAINER_CACHEDIR="/sharedFolder/apptainer/cache")
    os.makedirs(env["APPTAINER_CACHEDIR"], exist_ok=True)
    out = run(["apptainer", "exec", "docker://alpine:3.20", "cat", "/etc/alpine-release"], timeout=600, env=env)
    return "{}, ran an Alpine {} container".format(version, out)


def job(name, gpus, body, wait_minutes):
    if not os.path.exists(JOBQUEUE_CLI) or not os.environ.get("JUPYTERHUB_API_TOKEN"):
        raise Skip("no job queue here (not running inside JupyDo)")
    os.makedirs(SELFTEST_DIR, exist_ok=True)
    result = os.path.join(SELFTEST_DIR, name + ".txt")
    script = os.path.join(SELFTEST_DIR, name + ".sh")
    if os.path.exists(result):
        os.remove(result)
    with open(script, "w") as f:
        f.write("#!/bin/bash\n" + body.format(result=result))
    run([sys.executable, JOBQUEUE_CLI, "submit", script, "--time", "5m", "--cpus", "1", "--mem", "1",
         "--gpus", str(gpus), "--name", name], timeout=60)
    deadline = time.time() + 60 * wait_minutes
    while time.time() < deadline:
        if os.path.exists(result):
            return open(result).read().strip()
        time.sleep(5)
    return None


def job_queue(enabled, wait_minutes):
    if not enabled:
        raise Skip("--no-jobs")
    out = job("selftest-job", 0, 'echo "ran in $(hostname)" > {result}\n', wait_minutes)
    if out is None:
        raise Warn("the job did not finish within {} min (queue busy?): check the queue".format(wait_minutes))
    return "job " + out


def gpu_job(enabled, wait_minutes):
    if not enabled:
        raise Skip("--no-jobs or --no-gpu")
    out = job("selftest-gpu", 1, "(nvidia-smi -L || echo NO GPU) > {result} 2>&1\n", wait_minutes)
    if out is None:
        raise Warn("the GPU job did not start within {} min: no GPU on this server, or all busy".format(wait_minutes))
    if "GPU" not in out or out.startswith("NO GPU"):
        raise RuntimeError("the job ran but saw no GPU: " + out[:200])
    return out.splitlines()[0]


def main():
    ap = argparse.ArgumentParser(description="JupyDo environment self-test")
    ap.add_argument("--no-jobs", action="store_true")
    ap.add_argument("--no-gpu", action="store_true")
    ap.add_argument("--no-apptainer", action="store_true")
    ap.add_argument("--no-network", action="store_true")
    ap.add_argument("--wait", type=int, default=5, help="minutes to wait for each job")
    a = ap.parse_args()
    check("environment", environment)
    check("user", user)
    check("kernels found", kernels_found)
    for name, spec in kernel_list():
        check("kernel " + name, lambda name=name, spec=spec: start_kernel(name, spec))
    check("sudo", sudo)
    check("compilers", compilers)
    check("/sharedFolder", shared_folder)
    check("home folders", home_folders)
    check("network", lambda: network(not a.no_network))
    check("Apptainer", lambda: apptainer(not a.no_apptainer))
    check("job queue", lambda: job_queue(not a.no_jobs, a.wait))
    check("GPU job", lambda: gpu_job(not (a.no_jobs or a.no_gpu), a.wait))
    counts = {s: sum(1 for _, st, _ in RESULTS if st == s) for s in ("PASS", "WARN", "SKIP", "FAIL")}
    print("\nPASS {PASS} | WARN {WARN} | SKIP {SKIP} | FAIL {FAIL}".format(**counts))
    print("Everything available in this environment works." if counts["FAIL"] == 0
          else "{} check(s) FAILED: send this output to your JupyDo administrator.".format(counts["FAIL"]))
    return 1 if counts["FAIL"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
